import Foundation
import SwiftSignalKit
import CoreMedia
import AVFoundation
import TelegramCore
import TelegramAudio
import UniversalMediaPlayer
import AccountContext
import OpusBinding
import ChatPresentationInterfaceState
import AudioWaveform
import FFMpegBinding
import VoiceRecorderInput

private let kOutputBus: UInt32 = 0
private let kInputBus: UInt32 = 1

private func audioRecorderNativeStreamDescription(sampleRate: Float64) -> AudioStreamBasicDescription {
    var canonicalBasicStreamDescription = AudioStreamBasicDescription()
    canonicalBasicStreamDescription.mSampleRate = sampleRate
    canonicalBasicStreamDescription.mFormatID = kAudioFormatLinearPCM
    canonicalBasicStreamDescription.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
    canonicalBasicStreamDescription.mFramesPerPacket = 1
    canonicalBasicStreamDescription.mChannelsPerFrame = 1
    canonicalBasicStreamDescription.mBitsPerChannel = 16
    canonicalBasicStreamDescription.mBytesPerPacket = 2
    canonicalBasicStreamDescription.mBytesPerFrame = 2
    return canonicalBasicStreamDescription
}

private let beginToneData: TonePlayerData? = {
    guard let url = Bundle.main.url(forResource: "begin_record", withExtension: "mp3") else {
        return nil
    }
    return loadTonePlayerData(path: url.path)
}()

final class ManagedAudioRecorderContext {
    private let micLevel: ValuePromise<Float>
    private let recordingState: ValuePromise<AudioRecordingState>
    private let previewState: ValuePromise<AudioPreviewState>

    private let beginWithTone: Bool
    private let pauseMusicOnRecording: Bool
    private let beganWithTone: (Bool) -> Void
    
    private var trimRange: Range<Double>?
    
    private var paused = true
    
    private let queue: Queue
    private let mediaManager: MediaManager
    private var oggWriter: TGOggOpusWriter
    private var dataItem: TGDataItem
    // RemoteIO renders into this from its real-time thread (VoiceRecorderInputRenderCallback: no
    // Swift, locks, allocation or dispatch there); `drainTimer` takes 20 ms encoder packets from it
    // on `queue`. Freed in deinit, after the audio unit is disposed.
    private let input: OpaquePointer
    private static let encoderPacketSize = 16000 / 1000 * 60 * 2
    private let encoderPacket = UnsafeMutableRawPointer.allocate(byteCount: ManagedAudioRecorderContext.encoderPacketSize, alignment: 2)
    private var drainTimer: SwiftSignalKit.Timer?
    private var loggedRenderErrorCount: UInt32 = 0
    private var loggedDroppedBytes: UInt32 = 0
    
    private let audioUnit = Atomic<AudioUnit?>(value: nil)
    
    private var compressedWaveformSamples = Data()
    private var currentPeak: Int64 = 0
    private var currentPeakCount: Int = 0
    private var peakCompressionFactor: Int = 1
    
    private var micLevelPeak: Int16 = 0
    private var micLevelPeakCount: Int = 0
    private var audioLevelPeakUpdate: Double = 0.0
    
    private var recordingStateThrottle = VoiceRecordingStateThrottle()
    
    private var hasAudioSession = false
    private var audioSessionDisposable: Disposable?
    
    //private var tonePlayer: TonePlayer?
    private var toneRenderer: MediaPlayerAudioRenderer?
    private var toneRendererAudioSession: MediaPlayerAudioSessionCustomControl?
    private var toneRendererAudioSessionActivated = false
    
    private var processSamples = false
    
    private var toneTimer: SwiftSignalKit.Timer?
    private var idleTimerExtensionDisposable: Disposable?
    
    init(
        queue: Queue,
        mediaManager: MediaManager,
        resumeData: AudioRecorderResumeData?,
        pushIdleTimerExtension: @escaping () -> Disposable,
        micLevel: ValuePromise<Float>,
        recordingState: ValuePromise<AudioRecordingState>,
        previewState: ValuePromise<AudioPreviewState>,
        beginWithTone: Bool,
        pauseMusicOnRecording: Bool,
        beganWithTone: @escaping (Bool) -> Void
    ) {
        assert(queue.isCurrent())
        
        // Two seconds of 48 kHz 16-bit mono; RemoteIO cycles are at most a few thousand frames.
        // It returns nil only when these ~200 KB cannot be allocated.
        guard let input = VoiceRecorderInputCreate(192_000, 8192) else {
            fatalError("VoiceRecorderInputCreate failed")
        }
        self.input = input
        self.micLevel = micLevel
        self.beginWithTone = beginWithTone
        self.pauseMusicOnRecording = pauseMusicOnRecording
        self.beganWithTone = beganWithTone
        
        self.recordingState = recordingState
        self.previewState = previewState
        
        self.queue = queue
        self.mediaManager = mediaManager
        self.oggWriter = TGOggOpusWriter()
        
        if let resumeData {
            self.dataItem = TGDataItem(data: resumeData.compressedData)
        } else {
            self.dataItem = TGDataItem()
        }
        
        if beginWithTone, let toneData = audioRecordingToneData {
            self.processSamples = false
            let toneRenderer = MediaPlayerAudioRenderer(audioSession: .custom({ [weak self] control in
                queue.async {
                    if let strongSelf = self {
                        strongSelf.toneRendererAudioSession = control
                        if !strongSelf.paused && strongSelf.hasAudioSession {
                            strongSelf.toneRendererAudioSessionActivated = true
                            control.activate()
                        }
                    }
                }
                return ActionDisposable {
                }
            }), playAndRecord: true, soundMuted: false, ambient: false, mixWithOthers: false, forceAudioToSpeaker: false, baseRate: 1.0, audioLevelPipe: ValuePipe<Float>(), updatedRate: {
            }, audioPaused: {})
            self.toneRenderer = toneRenderer
            
            let toneDataOffset = Atomic<Int>(value: 0)
            toneRenderer.beginRequestingFrames(queue: DispatchQueue.global(), takeFrame: {
                let frameSize = 44100
                
                var takeRange: Range<Int>?
                let _ = toneDataOffset.modify { current in
                    let count = min(toneData.count - current, frameSize)
                    if count > 0 {
                        takeRange = current ..< (current + count)
                    }
                    return current + count
                }
                
                if let takeRange = takeRange {
                    var blockBuffer: CMBlockBuffer?
                    
                    let bytes = malloc(takeRange.count)!
                    toneData.withUnsafeBytes { rawDataBytes -> Void in
                        let dataBytes = rawDataBytes.baseAddress!.assumingMemoryBound(to: UInt8.self)

                        memcpy(bytes, dataBytes.advanced(by: takeRange.lowerBound), takeRange.count)
                    }
                    let status = CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: bytes, blockLength: takeRange.count, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: takeRange.count, flags: 0, blockBufferOut: &blockBuffer)
                    if status != noErr {
                        return .finished
                    }
                    
                    let sampleCount = takeRange.count / 2
                    
                    let pts = CMTime(value: Int64(takeRange.lowerBound / 2), timescale: 44100)
                    var timingInfo = CMSampleTimingInfo(duration: CMTime(value: Int64(sampleCount), timescale: 44100), presentationTimeStamp: pts, decodeTimeStamp: pts)
                    var sampleBuffer: CMSampleBuffer?
                    var sampleSize = takeRange.count
                    guard CMSampleBufferCreate(allocator: nil, dataBuffer: blockBuffer, dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: nil, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timingInfo, sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sampleBuffer) == noErr else {
                        return .finished
                    }
                    
                    if let sampleBuffer = sampleBuffer {
                        return .frame(MediaTrackFrame(type: .audio, sampleBuffer: sampleBuffer, resetDecoder: false, decoded: true))
                    } else {
                        return .finished
                    }
                } else {
                    return .finished
                }
            })
            toneRenderer.start()
            let toneTimer = SwiftSignalKit.Timer(timeout: 0.05, repeat: true, completion: { [weak self] in
                if let strongSelf = self {
                    var wait = false
                    
                    if let toneRenderer = strongSelf.toneRenderer {
                        let toneTime = CMTimebaseGetTime(toneRenderer.audioTimebase)
                        let endTime = CMTime(value: Int64(toneData.count / 2), timescale: 44100)
                        if CMTimeCompare(toneTime, endTime) >= 0 {
                            strongSelf.processSamples = true
                        } else {
                            wait = true
                        }
                    }
                    
                    if !wait {
                        strongSelf.toneTimer?.invalidate()
                    }
                }
                }, queue: queue)
            self.toneTimer = toneTimer
            toneTimer.start()
        } else {
            self.processSamples = true
        }
        
        /*if beginWithTone, let beginToneData = beginToneData {
         self.tonePlayer = TonePlayer()
         self.tonePlayer?.play(data: beginToneData, completed: { [weak self] in
         queue.async {
         guard let strongSelf = self else {
         return
         }
         let toneTimer = SwiftSignalKit.Timer(timeout: 0.3, repeat: false, completion: { [weak self] in
         guard let strongSelf = self else {
         return
         }
         strongSelf.processSamples = true
         }, queue: queue)
         strongSelf.toneTimer = toneTimer
         toneTimer.start()
         }
         })
         } else {
         self.processSamples = true
         }*/
        
        if let resumeData {
            guard let stateDict = try? JSONSerialization.jsonObject(with: resumeData.resumeData, options: []) as? [String: Any] else {
                Logger.shared.log("ManagedAudioRecorder", "Failed to deserialize JSON")
                return
            }
            // A draft's compressed data is the finished stream, which the paused encoder state does not match;
            // appending re-encodes it into a fresh writer instead.
            if !self.oggWriter.resume(with: self.dataItem, encoderState: stateDict) {
                self.oggWriter = TGOggOpusWriter()
                if !self.oggWriter.beginAppend(with: self.dataItem) {
                    Logger.shared.log("ManagedAudioRecorder", "Failed to resume OggWriter")
                    return
                }
            }
            // Restore the waveform of the audio recorded before the draft was saved (written by stop()).
            // Fewer than 200 entries keeps the `== 200` compaction trigger reachable.
            if let waveformString = stateDict["tg_waveform"] as? String, let waveformData = Data(base64Encoded: waveformString), waveformData.count % 2 == 0, waveformData.count / 2 < 200, let waveformFactor = stateDict["tg_waveformFactor"] as? Int, waveformFactor > 0 {
                self.compressedWaveformSamples = waveformData
                self.peakCompressionFactor = waveformFactor
            }
        } else {
            self.oggWriter.begin(with: self.dataItem)
        }
        
        self.idleTimerExtensionDisposable = (Signal<Void, NoError> { subscriber in
            return pushIdleTimerExtension()
        } |> delay(5.0, queue: queue)).start()
    }
    
    deinit {
        assert(self.queue.isCurrent())
        
        self.idleTimerExtensionDisposable?.dispose()
        
        self.stop()
        
        self.audioSessionDisposable?.dispose()
        
        self.toneRenderer?.stop()
        self.toneTimer?.invalidate()
        
        // stop() disposed the audio unit, so the callback no longer runs.
        VoiceRecorderInputDestroy(self.input)
        self.encoderPacket.deallocate()
    }
    
    private func setupAudioUnit() {
        guard self.audioUnit.with({ $0 }) == nil else {
            return
        }
        var desc = AudioComponentDescription()
        desc.componentType = kAudioUnitType_Output
        desc.componentSubType = kAudioUnitSubType_RemoteIO
        desc.componentFlags = 0
        desc.componentFlagsMask = 0
        desc.componentManufacturer = kAudioUnitManufacturer_Apple
        guard let inputComponent = AudioComponentFindNext(nil, &desc) else {
            return
        }
        var maybeAudioUnit: AudioUnit? = nil
        AudioComponentInstanceNew(inputComponent, &maybeAudioUnit)
        
        guard let audioUnit = maybeAudioUnit else {
            return
        }
        
        var one: UInt32 = 1
        guard AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, 4) == noErr else {
            AudioComponentInstanceDispose(audioUnit)
            return
        }
        
        var audioStreamDescription = audioRecorderNativeStreamDescription(sampleRate: 48000)
        guard AudioUnitSetProperty(audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &audioStreamDescription, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)) == noErr else {
            AudioComponentInstanceDispose(audioUnit)
            return
        }
        
        guard AudioUnitSetProperty(audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &audioStreamDescription, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)) == noErr else {
            AudioComponentInstanceDispose(audioUnit)
            return
        }
        
        var callbackStruct = AURenderCallbackStruct()
        callbackStruct.inputProc = VoiceRecorderInputRenderCallback
        callbackStruct.inputProcRefCon = UnsafeMutableRawPointer(self.input)
        guard AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callbackStruct, UInt32(MemoryLayout<AURenderCallbackStruct>.size)) == noErr else {
            AudioComponentInstanceDispose(audioUnit)
            return
        }
        
        var zero: UInt32 = 1
        guard AudioUnitSetProperty(audioUnit, kAudioUnitProperty_ShouldAllocateBuffer, kAudioUnitScope_Output, 0, &zero, 4) == noErr else {
            AudioComponentInstanceDispose(audioUnit)
            return
        }
        
        let _ = AudioUnitSetProperty(audioUnit, kAUVoiceIOProperty_MuteOutput, kAudioUnitScope_Global, 0, &zero, 4)
        
        guard AudioUnitInitialize(audioUnit) == noErr else {
            AudioComponentInstanceDispose(audioUnit)
            return
        }
        
        VoiceRecorderInputSetAudioUnit(self.input, audioUnit)
        let _ = self.audioUnit.swap(audioUnit)
    }
    
    func start() {
        assert(self.queue.isCurrent())
        
        self.paused = false
    
        if self.audioSessionDisposable == nil {
            let queue = self.queue
            self.audioSessionDisposable = self.mediaManager.audioSession.push(audioSessionType: .voiceMessageRecording(beginWithTone: self.beginWithTone, pauseMusicOnRecording: self.pauseMusicOnRecording), activate: { [weak self] state in
                queue.async {
                    if let strongSelf = self, !strongSelf.paused {
                        strongSelf.hasAudioSession = true
                        strongSelf.setupAudioUnit()
                        strongSelf.audioSessionAcquired(headset: state.isHeadsetConnected)
                    }
                }
            }, deactivate: { [weak self] _ in
                return Signal { subscriber in
                    queue.async {
                        if let strongSelf = self {
                            strongSelf.hasAudioSession = false
                            strongSelf.stop()
                            strongSelf.recordingState.set(.stopped)
                            subscriber.putCompletion()
                        }
                    }
                    
                    return EmptyDisposable
                }
            })
        }
    }
    
    func audioSessionAcquired(headset: Bool) {
        if let toneRenderer = self.toneRenderer, headset || self.beginWithTone {
            self.beganWithTone(true)
            if !self.toneRendererAudioSessionActivated {
                self.toneRendererAudioSessionActivated = true
                self.toneRendererAudioSession?.activate()
            }
            toneRenderer.setRate(1.0)
        } else {
            self.processSamples = true
            self.beganWithTone(false)
        }
        
        if let audioUnit = self.audioUnit.with({ $0 }) {
            guard AudioOutputUnitStart(audioUnit) == noErr else {
                self.stop()
                return
            }
            if self.drainTimer == nil {
                // About one RemoteIO cycle (~21 ms) and one mic-level update (25 ms) per tick.
                let drainTimer = SwiftSignalKit.Timer(timeout: 1.0 / 40.0, repeat: true, completion: { [weak self] in
                    self?.drainInput()
                }, queue: self.queue)
                self.drainTimer = drainTimer
                drainTimer.start()
            }
        }
    }
    
    func pause() {
        assert(self.queue.isCurrent())
        
        return self.stop()
    }
    
    func resume() {
        assert(self.queue.isCurrent())
        
        if let trimRange = self.trimRange, trimRange.lowerBound > 0.1 || trimRange.upperBound < self.oggWriter.encodedDuration() {
            if self.oggWriter.writeFrame(nil, frameByteCount: 0), let data = self.dataItem.data() {
                let previousDuration = self.oggWriter.encodedDuration()
                
                let tempSourceFile = EngineTempBox.shared.tempFile(fileName: "audio.ogg")
                let tempDestinationFile = EngineTempBox.shared.tempFile(fileName: "audio.ogg")
                
                try? data.write(to: URL(fileURLWithPath: tempSourceFile.path))
                
                // Swap in the trimmed file only if the trim and the append setup both succeed;
                // otherwise keep the untrimmed writer (and its waveform) rather than lose the recording.
                if FFMpegOpusTrimmer.trim(tempSourceFile.path, to: tempDestinationFile.path, start: trimRange.lowerBound, end: trimRange.upperBound), let trimmedData = try? Data(contentsOf: URL(fileURLWithPath: tempDestinationFile.path), options: []), !trimmedData.isEmpty {
                    let writer = TGOggOpusWriter()
                    if let item = TGDataItem(data: trimmedData), writer.beginAppend(with: item) {
                        self.dataItem = item
                        self.oggWriter = writer
                        
                        // Cut the waveform to the same range. Entries are Int16 peaks, each covering
                        // peakCompressionFactor samples at 48 kHz (the writer and RemoteIO rate), and they
                        // cover the tail of the audio (a recorder rebuilt from an old draft has no earlier entries).
                        let n = self.compressedWaveformSamples.count / 2
                        let entrySeconds = Double(self.peakCompressionFactor) / 48000.0
                        if n > 0 {
                            let coveredStart = max(0.0, previousDuration - (Double(n * self.peakCompressionFactor + self.currentPeakCount) / 48000.0))
                            let lo = max(0, min(n, Int((trimRange.lowerBound - coveredStart) / entrySeconds)))
                            let hi = max(lo, min(n, Int(((trimRange.upperBound - coveredStart) / entrySeconds).rounded(.up))))
                            self.compressedWaveformSamples = self.compressedWaveformSamples.subdata(in: lo * 2 ..< hi * 2)
                        }
                    }
                }
                                          
                EngineTempBox.shared.dispose(tempSourceFile)
                EngineTempBox.shared.dispose(tempDestinationFile)
                
                self.trimRange = nil
                self.previewState.set(AudioPreviewState(trimRange: self.trimRange))
            }
        } else if self.trimRange != nil {
            // A range that trims nothing must not be carried into the next segment.
            self.trimRange = nil
            self.previewState.set(AudioPreviewState(trimRange: nil))
        }
        
        self.start()
    }
    
    private var resumeData: Data?
    func stop() {
        assert(self.queue.isCurrent())
        
        var stoppedAudioUnit: AudioUnit?
        if let audioUnit = self.audioUnit.swap(nil) {
            stoppedAudioUnit = audioUnit
            let status = AudioOutputUnitStop(audioUnit)
            if status != noErr {
                Logger.shared.log("ManagedAudioRecorder", "AudioOutputUnitStop returned \(status)")
            }
            VoiceRecorderInputSetAudioUnit(self.input, nil)
        }
        self.drainTimer?.invalidate()
        self.drainTimer = nil
        // Encode what was recorded up to the stop; less than a packet stays for a resume.
        self.drainInput()
        
        let state = self.oggWriter.pause()
        
        self.paused = true
        
        if let audioUnit = stoppedAudioUnit {
            var status = noErr
            
            status = AudioUnitUninitialize(audioUnit)
            if status != noErr {
                Logger.shared.log("ManagedAudioRecorder", "AudioUnitUninitialize returned \(status)")
            }
            
            status = AudioComponentInstanceDispose(audioUnit)
            if status != noErr {
                Logger.shared.log("ManagedAudioRecorder", "AudioComponentInstanceDispose returned \(status)")
            }
        }
        
        if let toneRenderer = self.toneRenderer, self.toneRendererAudioSessionActivated {
            self.toneRendererAudioSessionActivated = false
            toneRenderer.stop()
        }
        
        let audioSessionDisposable = self.audioSessionDisposable
        self.audioSessionDisposable = nil
        audioSessionDisposable?.dispose()
        
        if let stateDict = state as? [String: Any] {
            // TGOggOpusWriter.restoreState reads only its own keys; the waveform rides along for a draft resume.
            var dict = stateDict
            dict["tg_waveform"] = self.compressedWaveformSamples.base64EncodedString()
            dict["tg_waveformFactor"] = self.peakCompressionFactor
            do {
                let jsonData = try JSONSerialization.data(withJSONObject: dict, options: [])
                self.resumeData = jsonData
            } catch {
                Logger.shared.log("ManagedAudioRecorder", "Failed to JSON: \(error)")
            }
        }
    }
    
    func updateTrimRange(start: Double, end: Double, updatedEnd: Bool, apply: Bool) {
        self.trimRange = start..<end
    }
    
    // Takes whole encoder packets from the input ring; a partial packet waits there for more
    // samples (also across a pause), as the previous per-buffer packetizer kept it.
    private func drainInput() {
        assert(self.queue.isCurrent())
        
        let renderErrorCount = VoiceRecorderInputRenderErrorCount(self.input)
        if renderErrorCount != self.loggedRenderErrorCount {
            Logger.shared.log("ManagedAudioRecorder", "AudioUnitRender returned \(VoiceRecorderInputLastRenderError(self.input)) (\(renderErrorCount &- self.loggedRenderErrorCount) times)")
            self.loggedRenderErrorCount = renderErrorCount
        }
        let droppedBytes = VoiceRecorderInputDroppedBytes(self.input)
        if droppedBytes != self.loggedDroppedBytes {
            Logger.shared.log("ManagedAudioRecorder", "input ring full, dropped \(droppedBytes &- self.loggedDroppedBytes) bytes")
            self.loggedDroppedBytes = droppedBytes
        }
        
        if self.paused {
            return
        }
        // Samples recorded while the start tone plays are not encoded.
        if !self.processSamples {
            VoiceRecorderInputDiscardAll(self.input)
            return
        }
        
        let packetSize = ManagedAudioRecorderContext.encoderPacketSize
        var encodedPacket = false
        while VoiceRecorderInputReadExactly(self.input, self.encoderPacket, UInt32(packetSize)) {
            self.processWaveformPreview(samples: self.encoderPacket.assumingMemoryBound(to: Int16.self), count: packetSize / 2)
            
            self.oggWriter.writeFrame(self.encoderPacket.assumingMemoryBound(to: UInt8.self), frameByteCount: UInt(packetSize))
            encodedPacket = true
        }
        // The duration after the packets of this tick, at most 30 times a second.
        if encodedPacket {
            let timestamp = CACurrentMediaTime()
            if self.recordingStateThrottle.shouldPublish(at: timestamp) {
                self.recordingState.set(.recording(duration: self.oggWriter.encodedDuration(), durationMediaTimestamp: timestamp))
            }
        }
    }
    
    func processWaveformPreview(samples: UnsafePointer<Int16>, count: Int) {
        for i in 0 ..< count {
            var sample = samples.advanced(by: i).pointee
            if sample < 0 {
                if sample == Int16.min {
                    sample = Int16.max
                } else {
                    sample = -sample
                }
            }
            
            self.currentPeak = max(Int64(sample), self.currentPeak)
            self.currentPeakCount += 1
            if self.currentPeakCount == self.peakCompressionFactor {
                var compressedPeak = Int16(clamping: self.currentPeak)
                withUnsafeBytes(of: &compressedPeak, { buffer in
                    self.compressedWaveformSamples.append(buffer.bindMemory(to: UInt8.self))
                })
                self.currentPeak = 0
                self.currentPeakCount = 0
                
                let compressedSampleCount = self.compressedWaveformSamples.count / 2
                if compressedSampleCount == 200 {
                    self.compressedWaveformSamples.withUnsafeMutableBytes { rawCompressedSamples -> Void in
                        let compressedSamples = rawCompressedSamples.baseAddress!.assumingMemoryBound(to: Int16.self)

                        for i in 0 ..< 100 {
                            let maxSample = Int64(max(compressedSamples[i * 2 + 0], compressedSamples[i * 2 + 1]))
                            compressedSamples[i] = Int16(maxSample)
                        }
                    }
                    self.compressedWaveformSamples.count = 100 * 2
                    self.peakCompressionFactor *= 2
                }
            }
            
            if self.micLevelPeak < sample {
                self.micLevelPeak = sample
            }
            self.micLevelPeakCount += 1
            
            if self.micLevelPeakCount >= 1200 {
                let level = Float(self.micLevelPeak) / 4000.0
                /*let timestamp = CFAbsoluteTimeGetCurrent()
                if !self.audioLevelPeakUpdate.isZero {
                    let delta = timestamp - self.audioLevelPeakUpdate
                    print("level = \(level), delta = \(delta)")
                }
                self.audioLevelPeakUpdate = timestamp*/
                self.micLevel.set(level)
                self.micLevelPeak = 0
                self.micLevelPeakCount = 0
            }
        }
    }
    
    func takeData() -> RecordedAudioData? {
        // writeFrame(nil) finishes the stream for good: the writer drops every later frame. Finish a copy and
        // put the live writer back from its paused state, so a resumed recording keeps appending.
        let liveState = self.oggWriter.pause()
        let liveData = self.dataItem.data()
        defer {
            let dataItem: TGDataItem = TGDataItem(data: liveData)
            let oggWriter = TGOggOpusWriter()
            if oggWriter.resume(with: dataItem, encoderState: liveState) {
                self.dataItem = dataItem
                self.oggWriter = oggWriter
            } else {
                Logger.shared.log("ManagedAudioRecorder", "Failed to restore OggWriter after taking data")
            }
        }

        if self.oggWriter.writeFrame(nil, frameByteCount: 0) {
            let scaledSamplesMemory = malloc(100 * 2)!
            let scaledSamples: UnsafeMutablePointer<Int16> = scaledSamplesMemory.assumingMemoryBound(to: Int16.self)
            defer {
                free(scaledSamplesMemory)
            }
            memset(scaledSamples, 0, 100 * 2);
            var waveform: Data?
            
            let count = self.compressedWaveformSamples.count / 2
            self.compressedWaveformSamples.withUnsafeMutableBytes { rawSamples -> Void in
                let samples = rawSamples.baseAddress!.assumingMemoryBound(to: Int16.self)

                for i in 0 ..< count {
                    let sample = samples[i]
                    let index = i * 100 / count
                    if (scaledSamples[index] < sample) {
                        scaledSamples[index] = sample;
                    }
                }
                
                var peak: Int16 = 0
                var sumSamples: Int64 = 0
                for i in 0 ..< 100 {
                    let sample = scaledSamples[i]
                    if peak < sample {
                        peak = sample
                    }
                    sumSamples += Int64(sample)
                }
                var calculatedPeak: UInt16 = 0
                calculatedPeak = UInt16((Double(sumSamples) * 1.8 / 100.0))
                
                if calculatedPeak < 2500 {
                    calculatedPeak = 2500
                }
                
                for i in 0 ..< 100 {
                    let sample: UInt16 = UInt16(Int64(scaledSamples[i]))
                    let minPeak = min(Int64(sample), Int64(calculatedPeak))
                    let resultPeak = minPeak * 31 / Int64(calculatedPeak)
                    scaledSamples[i] = Int16(clamping: min(31, resultPeak))
                }
                
                let resultWaveform = AudioWaveform(samples: Data(bytes: scaledSamplesMemory, count: 100 * 2), peak: 31)
                let bitstream = resultWaveform.makeBitstream()
                waveform = AudioWaveform(bitstream: bitstream, bitsPerSample: 5).makeBitstream()
            }
            
            return RecordedAudioData(
                compressedData: self.dataItem.data(),
                resumeData: self.resumeData,
                duration: self.oggWriter.encodedDuration(),
                waveform: waveform,
                trimRange: nil
            )
        } else {
            return nil
        }
    }
}

struct AudioPreviewState: Equatable {
    let trimRange: Range<Double>?
}

final class ManagedAudioRecorderImpl: ManagedAudioRecorder {
    private let queue = Queue()
    private var contextRef: Unmanaged<ManagedAudioRecorderContext>?
    private let micLevelValue = ValuePromise<Float>(0.0)
    private let recordingStateValue = ValuePromise<AudioRecordingState>(.paused(duration: 0.0))
    private let previewStateValue = ValuePromise<AudioPreviewState>(AudioPreviewState(trimRange: nil))
    
    let beginWithTone: Bool
    
    var micLevel: Signal<Float, NoError> {
        return self.micLevelValue.get()
    }
    
    var recordingState: Signal<AudioRecordingState, NoError> {
        return self.recordingStateValue.get()
    }
    
    init(
        mediaManager: MediaManager,
        resumeData: AudioRecorderResumeData?,
        pushIdleTimerExtension: @escaping () -> Disposable,
        beginWithTone: Bool,
        pauseMusicOnRecording: Bool,
        beganWithTone: @escaping (Bool) -> Void
    ) {
        self.beginWithTone = beginWithTone
        self.queue.async {
            let context = ManagedAudioRecorderContext(queue: self.queue, mediaManager: mediaManager, resumeData: resumeData, pushIdleTimerExtension: pushIdleTimerExtension, micLevel: self.micLevelValue, recordingState: self.recordingStateValue, previewState: self.previewStateValue, beginWithTone: beginWithTone, pauseMusicOnRecording: pauseMusicOnRecording, beganWithTone: beganWithTone)
            self.contextRef = Unmanaged.passRetained(context)
        }
    }
    
    deinit {
        let contextRef = self.contextRef
        self.queue.async {
            contextRef?.release()
        }
    }
    
    func start() {
        self.queue.async {
            if let context = self.contextRef?.takeUnretainedValue() {
                context.start()
            }
        }
    }
    
    func pause() {
        self.queue.async {
            if let context = self.contextRef?.takeUnretainedValue() {
                context.pause()
            }
        }
    }
    
    func resume() {
        self.queue.async {
            if let context = self.contextRef?.takeUnretainedValue() {
                context.resume()
            }
        }
    }
    
    func stop() {
        self.queue.async {
            if let context = self.contextRef?.takeUnretainedValue() {
                context.stop()
            }
        }
    }
    
    func takenRecordedData() -> Signal<RecordedAudioData?, NoError> {
        let dataState: Signal<RecordedAudioData?, NoError> = Signal { subscriber in
            self.queue.async {
                if let context = self.contextRef?.takeUnretainedValue() {
                    subscriber.putNext(context.takeData())
                    subscriber.putCompletion()
                } else {
                    subscriber.putNext(nil)
                    subscriber.putCompletion()
                }
            }
            return EmptyDisposable
        }
        let previewState = self.previewStateValue.get()
        
        return combineLatest(
            dataState,
            previewState
        ) |> map { data, preview -> RecordedAudioData? in
            if let data {
                return RecordedAudioData(
                    compressedData: data.compressedData,
                    resumeData: data.resumeData,
                    duration: data.duration,
                    waveform: data.waveform,
                    trimRange: preview.trimRange
                )
            } else {
                return nil
            }
        }
    }
    
    func updateTrimRange(start: Double, end: Double, updatedEnd: Bool, apply: Bool) {
        self.previewStateValue.set(AudioPreviewState(trimRange: start ..< end))
        self.queue.async {
            if let context = self.contextRef?.takeUnretainedValue() {
                context.updateTrimRange(start: start, end: end, updatedEnd: updatedEnd, apply: apply)
            }
        }
    }
}
