import Foundation
import Postbox
internal import TelegramApi
import SwiftSignalKit
import MtProtoKit
import CryptoUtils
import ManagedFile

private typealias SignalKitTimer = SwiftSignalKit.Timer


struct UploadPart {
    let fileId: Int64
    let index: Int
    let data: Data
    let bigTotalParts: Int?
    let bigPart: Bool
    /// The part's offset in the file, which is the manager's key for it.
    var offset: Int64 = 0
    /// Called by the retry wrapper with the back-off delay when this part's request is sent again.
    var onRetry: ((Double) -> Void)? = nil
}

/// Carries a part's retry notice from the request signal back to the manager that owns the window. Weakly bound
/// by the manager, so a retry that fires after the upload ended reaches nothing.
final class UploadPartRetrySink {
    /// Offset, the file id the part belongs to, when the notice was raised, and the back-off delay.
    var onRetry: ((Int64, Int64, Double, Double) -> Void)?
}

private func md5(_ data: Data) -> Data {
    return data.withUnsafeBytes { rawBytes -> Data in
        let bytes = rawBytes.baseAddress!
        return CryptoMD5(bytes, Int32(data.count))
    }
}

final class MultipartUploadState {
    let aesKey: Data
    var aesIv: Data
    var effectiveSize: Int64 = 0
    
    init(encryptionKey: SecretFileEncryptionKey?) {
        if let encryptionKey = encryptionKey {
            self.aesKey = encryptionKey.aesKey
            self.aesIv = encryptionKey.aesIv
        } else {
            self.aesKey = Data()
            self.aesIv = Data()
        }
    }
    
    func transformHeader(data: Data) -> Data {
        assert(self.aesKey.isEmpty)
        self.effectiveSize += Int64(data.count)
        return data
    }
    
    func transform(data: Data) -> Data {
        if self.aesKey.count != 0 {
            var encryptedData = data
            var paddingSize = 0
            while (encryptedData.count + paddingSize) % 16 != 0 {
                paddingSize += 1
            }
            if paddingSize != 0 {
                encryptedData.count = encryptedData.count + paddingSize
            }
            let encryptedDataCount = encryptedData.count
            encryptedData.withUnsafeMutableBytes { rawBytes -> Void in
                let bytes = rawBytes.baseAddress!.assumingMemoryBound(to: UInt8.self)
                if paddingSize != 0 {
                    arc4random_buf(bytes.advanced(by: encryptedDataCount - paddingSize), paddingSize)
                }
                self.aesIv.withUnsafeMutableBytes { rawIv -> Void in
                    let iv = rawIv.baseAddress!.assumingMemoryBound(to: UInt8.self)
                    MTAesEncryptBytesInplaceAndModifyIv(bytes, encryptedDataCount, self.aesKey, iv)
                }
            }
            self.effectiveSize += Int64(encryptedData.count)
            return encryptedData
        } else {
            self.effectiveSize += Int64(data.count)
            return data
        }
    }
    
    func finalize() -> Int64 {
        return self.effectiveSize
    }
}

struct MultipartIntermediateResult {
    let id: Int64
    let partCount: Int32
    let md5Digest: String
    let size: Int64
    let bigTotalParts: Int?
}

enum MultipartUploadData {
    case resourceData(MediaResourceData)
    case data(Data)
    
    var size: Int64 {
        switch self {
        case let .resourceData(data):
            return data.size
        case let .data(data):
            return Int64(data.count)
        }
    }
    var complete: Bool {
        switch self {
        case let .resourceData(data):
            return data.complete
        case .data:
            return true
        }
    }
}

enum HeaderPartState {
    case notStarted
    case uploading
    case ready
}

final class MultipartUploadManager {
    private let increaseParallelParts: Bool
    /// Parts in flight. History import (`increaseParallelParts`) always gets 30. Otherwise `UploadPartWindow` decides:
    /// it starts at six for parts under 512 KB (bound by latency; measured on a 4.6 MB video: 2.9 -> 4.5 MB/s, and
    /// 4.1 -> 2.7 s with 200 ms of added latency) and three for 512 KB parts (three already fill the link), lower on
    /// cellular, and follows how fast parts really finish.
    var parallelParts: Int {
        if self.increaseParallelParts {
            return 30
        } else {
            return self.window.allowedInFlight
        }
    }
    private var window: UploadPartWindow
    private let now: () -> Double
    private let stallTimeout: Double
    private let finishLog: ((String) -> Void)?
    private let networkIsInjected: Bool
    private var lastNetworkDescription: String
    private let startNetworkName: String
    private let retrySink = UploadPartRetrySink()
    private var partTimers: [Int64: Disposable] = [:]
    private var hardTimers: [Int64: Disposable] = [:]
    private struct PartRequest {
        let signal: Signal<Void, UploadPartError>
        let partIndex: Int
        let isHeader: Bool
    }
    private var partRequests: [Int64: PartRequest] = [:]
    private var reissuedParts = Set<Int64>()
    private let hardDeadlineOverride: Double?
    /// Phase 2 of the first-answer limit: a part with no answer for `hardDeadline` is sent once more, then fails.
    /// Off until it has run on a device on a slow and an offline link: it fails uploads that are slow but alive.
    /// Even when on, a part is sent again only while other parts of this upload are still being answered.
    nonisolated(unsafe) static var hardDeadlineEnabled = false
    private let hardDeadlineAllowed: Bool
    /// Parts of this upload that finished so far, and their bytes, for the proof that the link is alive.
    private var finishedCount = 0
    private var finishedBytes: Int64 = 0
    /// Per part in flight: finished-part counter and time when its request was last issued or sent again.
    private var issuedAt: [Int64: (count: Int, at: Double)] = [:]
    private var finishLogged = false
    private var startedAt: Double
    var defaultPartSize: Int64
    var bigTotalParts: Int?
    var bigParts: Bool
    private let forceNoBigParts: Bool
    private let useLargerParts: Bool
    
    let queue = Queue()
    private(set) var fileId: Int64
    
    let dataSignal: Signal<MultipartUploadData, NoError>
    
    var committedOffset: Int64
    let uploadPart: (UploadPart) -> Signal<Void, UploadPartError>
    let progress: (Float) -> Void
    let completed: (MultipartIntermediateResult?) -> Void
    
    var uploadingParts: [Int64: (Int64, Disposable)] = [:]
    var uploadedParts: [Int64: Int64] = [:]
    
    let dataDisposable = MetaDisposable()
    var resourceData: MultipartUploadData?
    
    var headerPartState: HeaderPartState
    let headerSize: () -> Int64
    var heldHeaderLength: Int64 = 0
    var pendingHeaderOffsets: [Int64] = []
    private var hasHeaderPart: Bool {
        return self.headerSize() != 0
    }
    
    let state: MultipartUploadState
    
    init(headerSize: @escaping () -> Int64, data: Signal<MultipartUploadData, NoError>, encryptionKey: SecretFileEncryptionKey?, hintFileSize: Int64?, hintFileIsLarge: Bool, forceNoBigParts: Bool, useLargerParts: Bool, increaseParallelParts: Bool, hardDeadlineAllowed: Bool = true, networkClass: UploadPartWindow.NetworkClass? = nil, stallTimeout: Double = 8.0, hardDeadline: Double? = nil, now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }, finishLog: ((String) -> Void)? = nil, uploadPart: @escaping (UploadPart) -> Signal<Void, UploadPartError>, progress: @escaping (Float) -> Void, completed: @escaping (MultipartIntermediateResult?) -> Void) {
        self.dataSignal = data
        
        var fileId: Int64 = 0
        arc4random_buf(&fileId, 8)
        self.fileId = fileId
        
        self.increaseParallelParts = increaseParallelParts
        self.hardDeadlineAllowed = hardDeadlineAllowed
        
        self.forceNoBigParts = forceNoBigParts
        self.useLargerParts = useLargerParts
        
        self.state = MultipartUploadState(encryptionKey: encryptionKey)
        
        self.committedOffset = 0
        self.uploadPart = uploadPart
        self.progress = progress
        self.completed = completed
        
        self.headerSize = headerSize
        if headerSize() == 0 {
            self.headerPartState = .ready
        } else {
            self.headerPartState = .notStarted
        }
        
        if let hintFileSize = hintFileSize, hintFileSize > 10 * 1024 * 1024, !forceNoBigParts {
            self.defaultPartSize = 512 * 1024
            self.bigTotalParts = Int((hintFileSize / self.defaultPartSize) + (hintFileSize % self.defaultPartSize == 0 ? 0 : 1))
            self.bigParts = true
        } else if hintFileIsLarge, !forceNoBigParts {
            self.defaultPartSize = 512 * 1024
            self.bigTotalParts = nil
            self.bigParts = true
        } else if useLargerParts {
            self.bigParts = false
            self.defaultPartSize = 256 * 1024
            self.bigTotalParts = nil
        } else {
            self.bigParts = false
            self.defaultPartSize = 128 * 1024
            self.bigTotalParts = nil
        }
        
        self.now = now
        self.stallTimeout = stallTimeout
        self.hardDeadlineOverride = hardDeadline
        self.finishLog = finishLog
        self.startedAt = now()
        let startDescription = pendingFailureNetworkDescription()
        let resolvedNetwork = networkClass ?? MultipartUploadManager.networkClass(description: startDescription)
        self.networkIsInjected = networkClass != nil
        self.lastNetworkDescription = startDescription
        self.startNetworkName = networkClass != nil ? resolvedNetwork.rawValue : startDescription
        self.window = UploadPartWindow(UploadPartWindow.Config(partSize: Int(self.defaultPartSize), network: resolvedNetwork))
        self.retrySink.onRetry = { [weak self] offset, fileId, raisedAt, delay in
            guard let self else {
                return
            }
            let at = self.now()
            self.queue.async { [weak self] in
                self?.partRetried(offset: offset, fileId: fileId, raisedAt: raisedAt, at: at, delay: delay)
            }
        }
    }
    
    private static func networkClass(description: String) -> UploadPartWindow.NetworkClass {
        switch description {
        case "wifi":
            return .wifi
        case "cellular":
            return .cellular
        default:
            return .unknown
        }
    }
    
    deinit {
        let uploadingParts = self.uploadingParts
        let partTimers = self.partTimers
        let hardTimers = self.hardTimers
        let dataDisposable = self.dataDisposable
        
        self.queue.async {
            for (_, timer) in partTimers {
                timer.dispose()
            }
            for (_, timer) in hardTimers {
                timer.dispose()
            }
            for (_, (_, disposable)) in uploadingParts {
                disposable.dispose()
            }
            dataDisposable.dispose()
        }
    }
    
    func start() {
        self.queue.async { [self] in
            self.startedAt = self.now()
            self.dataDisposable.set((self.dataSignal
            |> deliverOn(self.queue)).startStrict(next: { [weak self] data in
                if let strongSelf = self {
                    strongSelf.resourceData = data
                    strongSelf.checkState()
                }
            }))
        }
    }
    
    func cancel() {
        self.queue.async {
            self.cancelPartTimers()
            for (_, (_, disposable)) in self.uploadingParts {
                disposable.dispose()
            }
        }
    }
    
    func checkState() {
        if let resourceData = self.resourceData, !resourceData.complete, !self.bigParts, !self.forceNoBigParts, resourceData.size > 10 * 1024 * 1024, self.uploadedParts.isEmpty, self.uploadingParts.isEmpty, self.committedOffset <= self.heldHeaderLength {
            // Nothing beyond the held header went out yet. Once small parts are committed, the restart below handles the crossing.
            self.updatePartSize(512 * 1024)
            self.bigTotalParts = nil
            self.bigParts = true
            self.committedOffset = 0
            self.heldHeaderLength = 0
        }
        if let resourceData = self.resourceData, resourceData.complete, resourceData.size > 10 * 1024 * 1024, !self.bigParts, !self.forceNoBigParts, self.committedOffset != 0 || !self.uploadedParts.isEmpty || !self.uploadingParts.isEmpty {
            // Parts went out while the file was still growing, as a small file; it ended up over the
            // small-file limit, which the server accepts only as a big file. Start over under a new id.
            self.cancelPartTimers()
            for (_, (_, disposable)) in self.uploadingParts {
                disposable.dispose()
            }
            self.uploadingParts.removeAll()
            self.uploadedParts.removeAll()
            self.window.restart(partSize: Int(self.defaultPartSize), at: self.now())
            self.committedOffset = 0
            // Only an unencrypted upload sends parts before the data is complete, so the count is all there is to reset.
            self.state.effectiveSize = 0
            self.heldHeaderLength = 0
            self.pendingHeaderOffsets.removeAll()
            self.headerPartState = self.hasHeaderPart ? .notStarted : .ready
            var fileId: Int64 = 0
            arc4random_buf(&fileId, 8)
            self.fileId = fileId
        }
        if let resourceData = self.resourceData, resourceData.complete && resourceData.size != 0 {
            if self.committedOffset == 0 && self.uploadedParts.isEmpty && self.uploadingParts.isEmpty {
                if resourceData.size > 10 * 1024 * 1024, !self.forceNoBigParts {
                    self.updatePartSize(512 * 1024)
                    self.bigTotalParts = Int(resourceData.size / self.defaultPartSize) + (resourceData.size % self.defaultPartSize == 0 ? 0 : 1)
                    self.bigParts = true
                } else {
                    self.bigParts = false
                    if self.useLargerParts {
                        self.updatePartSize(256 * 1024)
                    } else {
                        // 128 KB, as before the size was known: 16 KB parts cost a round trip per 48 KB
                        // (measured: a 120 KB photo in 1.04 -> 0.48 s with 200 ms of added latency).
                        self.updatePartSize(128 * 1024)
                    }
                    self.bigTotalParts = nil
                }
            }
        }
        
        var updatedCommittedOffset = false
        for offset in self.uploadedParts.keys.sorted() {
            if offset == self.committedOffset {
                let partSize = self.uploadedParts[offset]!
                self.committedOffset += partSize
                updatedCommittedOffset = true
                let _ = self.uploadedParts.removeValue(forKey: offset)
            }
        }
        if updatedCommittedOffset {
            if let resourceData = self.resourceData, resourceData.complete && resourceData.size != 0 {
                self.progress(Float(self.committedOffset) / Float(resourceData.size))
            }
        }
        
        if let resourceData = self.resourceData, resourceData.complete, self.committedOffset >= resourceData.size {
            switch self.headerPartState {
                case .ready:
                    let effectiveSize = self.state.finalize()
                    let effectivePartCount = Int32(effectiveSize / self.defaultPartSize + (effectiveSize % self.defaultPartSize == 0 ? 0 : 1))
                    var currentBigTotalParts = self.bigTotalParts
                    if self.bigParts {
                        currentBigTotalParts = Int(resourceData.size / self.defaultPartSize) + (resourceData.size % self.defaultPartSize == 0 ? 0 : 1)
                    }
                    self.finish(MultipartIntermediateResult(id: self.fileId, partCount: effectivePartCount, md5Digest: "", size: resourceData.size, bigTotalParts: currentBigTotalParts))
                case .notStarted:
                    let headerLength = self.heldHeaderLength > 0 ? self.heldHeaderLength : self.defaultPartSize
                    var offsets = Array(stride(from: Int64(0), to: min(headerLength, resourceData.size), by: Int(self.defaultPartSize)))
                    if offsets.isEmpty {
                        offsets = [0]
                    }
                    self.pendingHeaderOffsets = offsets
                    self.headerPartState = .uploading
                    self.uploadPendingHeaderParts(resourceData: resourceData)
                case .uploading:
                    self.uploadPendingHeaderParts(resourceData: resourceData)
            }
        } else if let resourceData = self.resourceData, self.state.aesKey.isEmpty || resourceData.complete {
            while uploadingParts.count < self.parallelParts {
                switch self.headerPartState {
                    case .notStarted:
                        if self.committedOffset == 0, !resourceData.complete, resourceData.size > 0 {
                            let headerSize = max(1, self.headerSize())
                            let headerParts = headerSize / self.defaultPartSize + (headerSize % self.defaultPartSize == 0 ? 0 : 1)
                            self.heldHeaderLength = headerParts * self.defaultPartSize
                            self.committedOffset += self.heldHeaderLength
                        }
                    case .ready, .uploading:
                        break
                }
                
                var nextOffset = self.committedOffset
                for (offset, (size, _)) in self.uploadingParts {
                    nextOffset = max(nextOffset, offset + size)
                }
                for (offset, partSize) in self.uploadedParts {
                    nextOffset = max(nextOffset, offset + partSize)
                }
                
                let partOffset = nextOffset
                let partSize = min(resourceData.size - partOffset, self.defaultPartSize)
                
                if nextOffset < resourceData.size && partSize > 0 && (resourceData.complete || partSize == self.defaultPartSize) {
                    let partIndex = Int(partOffset / self.defaultPartSize)
                    if let partData = self.readPart(resourceData: resourceData, offset: partOffset, size: partSize) {
                        let partData = self.state.transform(data: partData)
                        var currentBigTotalParts = self.bigTotalParts
                        if self.bigParts && resourceData.complete && partOffset + partSize == resourceData.size {
                            currentBigTotalParts = Int(resourceData.size / self.defaultPartSize) + (resourceData.size % self.defaultPartSize == 0 ? 0 : 1)
                        }
                        let part = self.uploadPart(UploadPart(fileId: self.fileId, index: partIndex, data: partData, bigTotalParts: currentBigTotalParts, bigPart: self.bigParts, offset: partOffset, onRetry: self.retryNotice(offset: partOffset)))
                        |> deliverOn(self.queue)
                        if partIndex == 0 {
                            switch self.headerPartState {
                                case .notStarted:
                                    self.headerPartState = .uploading
                                case .ready, .uploading:
                                    break
                            }
                        }
                        self.partWillStart(offset: partOffset, size: partSize)
                        self.partRequests[partOffset] = PartRequest(signal: part, partIndex: partIndex, isHeader: false)
                        self.startPart(part, offset: partOffset, size: partSize, partIndex: partIndex, isHeader: false)
                    } else {
                        self.finish(nil)
                        return
                    }
                } else {
                    break
                }
            }
        }
    }
    
    /// Sets the part size and starts the window over for it. Only legal while nothing is in flight.
    private func updatePartSize(_ size: Int64) {
        self.defaultPartSize = size
        self.window.restart(partSize: Int(size), at: self.now())
    }
    
    private func retryNotice(offset: Int64) -> (Double) -> Void {
        let sink = self.retrySink
        let fileId = self.fileId
        let now = self.now
        return { delay in
            sink.onRetry?(offset, fileId, now(), delay)
        }
    }
    
    /// Records the part as in flight, then starts its request. The entry goes in first: a request may answer, fail or
    /// report a retry while it is being subscribed (on this queue, so synchronously), and it must find the part in flight;
    /// storing the subscription afterwards would leave a finished part in `uploadingParts` and drop the retry notice.
    private func startPart(_ part: Signal<Void, UploadPartError>, offset: Int64, size: Int64, partIndex: Int, isHeader: Bool) {
        let subscription = MetaDisposable()
        self.uploadingParts[offset] = (size, subscription)
        subscription.set(self.subscribe(part, offset: offset, size: size, partIndex: partIndex, isHeader: isHeader))
    }
    
    /// Starts one part's request signal. Also used to send the same part again after a hard deadline.
    private func subscribe(_ part: Signal<Void, UploadPartError>, offset: Int64, size: Int64, partIndex: Int, isHeader: Bool) -> Disposable {
        return part.startStrict(error: { [weak self] error in
            pendingMessageFailureLog("upload \(isHeader ? "header part at \(offset)" : "part \(partIndex)") of \(size) bytes failed (\(error)), \(self?.uploadingParts.count ?? 0) in flight")
            self?.partDidFail(offset: offset)
            self?.finish(nil)
        }, completed: { [weak self] in
            guard let strongSelf = self else {
                return
            }
            strongSelf.partDidFinish(offset: offset)
            strongSelf.uploadingParts.removeValue(forKey: offset)?.1.dispose()
            if isHeader {
                if strongSelf.pendingHeaderOffsets.isEmpty && strongSelf.uploadingParts.isEmpty {
                    strongSelf.headerPartState = .ready
                }
            } else {
                strongSelf.uploadedParts[offset] = size
                if partIndex == 0 {
                    strongSelf.headerPartState = .ready
                }
            }
            strongSelf.checkState()
        })
    }
    
    /// Seconds a part may go without any answer before it is sent once more: the engine's own response allowance
    /// (12 s plus 12 KB/s, as MtProtoKit computes it) for the bytes queued ahead of it on this upload plus its own, at
    /// the measured goodput of this upload (never below 12 KB/s), and a margin of 8 s.
    private func hardDeadline(offset: Int64, size: Int64) -> Double {
        if let override = self.hardDeadlineOverride {
            return override
        }
        var ahead: Int64 = 0
        for (otherOffset, (otherSize, _)) in self.uploadingParts where otherOffset != offset {
            ahead += otherSize
        }
        var rate = 12.0 * 1024.0
        let elapsed = self.now() - self.startedAt
        if self.finishedBytes > 0 && elapsed > 0.001 {
            rate = max(rate, Double(self.finishedBytes) / elapsed)
        }
        return 12.0 + Double(ahead + size) / rate + 8.0
    }
    
    private func armHardDeadline(offset: Int64, size: Int64, after delay: Double, scale: Double = 1.0) {
        guard MultipartUploadManager.hardDeadlineEnabled, self.hardDeadlineAllowed, !self.increaseParallelParts else {
            return
        }
        self.hardTimers.removeValue(forKey: offset)?.dispose()
        let timer = SignalKitTimer(timeout: delay + self.hardDeadline(offset: offset, size: size) * scale, repeat: false, completion: { [weak self] in
            self?.hardDeadlineExpired(offset: offset)
        }, queue: self.queue)
        self.hardTimers[offset] = ActionDisposable {
            timer.invalidate()
        }
        timer.start()
    }
    
    /// First expiry: if another part of this upload was answered since this one was issued and the device is online,
    /// the same signal is subscribed again (same file id, part index and bytes, so the server overwrites the part;
    /// the bytes were encrypted once when the signal was built); otherwise the clock restarts, since the part may only
    /// be waiting behind others, offline or in a flood wait. Second expiry: the upload fails only if no part of it
    /// was answered during the whole period and the device is online; else the clock restarts with a doubled limit.
    private func hardDeadlineExpired(offset: Int64) {
        self.hardTimers.removeValue(forKey: offset)
        guard let (size, subscription) = self.uploadingParts[offset], let request = self.partRequests[offset] else {
            return
        }
        let issued = self.issuedAt[offset] ?? (count: 0, at: self.startedAt)
        let progressed = self.finishedCount > issued.count
        let online = self.networkIsInjected || pendingFailureNetworkDescription() != "none"
        if self.reissuedParts.contains(offset) {
            if progressed || !online {
                self.issuedAt[offset] = (count: self.finishedCount, at: issued.at)
                self.armHardDeadline(offset: offset, size: size, after: 0, scale: 2.0)
                return
            }
            pendingMessageFailureLog("upload part at \(offset) of \(size) bytes got no answer twice, giving up")
            self.partDidFail(offset: offset)
            self.finish(nil)
            return
        }
        if !progressed || !online {
            self.armHardDeadline(offset: offset, size: size, after: 0)
            return
        }
        pendingMessageFailureLog("upload part at \(offset) of \(size) bytes got no answer, sending it again")
        self.reissuedParts.insert(offset)
        subscription.dispose()
        let at = self.now()
        self.issuedAt[offset] = (count: self.finishedCount, at: at)
        self.window.partRetried(id: offset, at: at, resumesAt: at)
        self.startPart(request.signal, offset: offset, size: size, partIndex: request.partIndex, isHeader: request.isHeader)
        if self.uploadingParts[offset] != nil {
            self.armHardDeadline(offset: offset, size: size, after: 0)
        }
    }
    
    private func partWillStart(offset: Int64, size: Int64) {
        self.window.partStarted(id: offset, bytes: Int(size), inFlight: self.uploadingParts.count, at: self.now())
        self.issuedAt[offset] = (count: self.finishedCount, at: self.now())
        self.armStallTimer(offset: offset, after: self.stallTimeout)
        self.armHardDeadline(offset: offset, size: size, after: 0)
    }
    
    private func partDidFinish(offset: Int64) {
        self.partTimers.removeValue(forKey: offset)?.dispose()
        self.hardTimers.removeValue(forKey: offset)?.dispose()
        self.partRequests.removeValue(forKey: offset)
        self.reissuedParts.remove(offset)
        self.issuedAt.removeValue(forKey: offset)
        self.finishedCount += 1
        self.finishedBytes += self.uploadingParts[offset]?.0 ?? 0
        let at = self.now()
        self.window.partFinished(id: offset, at: at)
        self.checkNetwork(at: at)
    }
    
    private func partDidFail(offset: Int64) {
        self.partTimers.removeValue(forKey: offset)?.dispose()
        self.hardTimers.removeValue(forKey: offset)?.dispose()
        self.issuedAt.removeValue(forKey: offset)
        self.window.partFailed(id: offset, at: self.now())
    }
    
    private func partRetried(offset: Int64, fileId: Int64, raisedAt: Double, at: Double, delay: Double) {
        // A notice raised before the part was last sent again, or for an attempt of an earlier file id (the upload
        // started over), belongs to a request that is gone.
        guard fileId == self.fileId, self.uploadingParts[offset] != nil, raisedAt >= (self.issuedAt[offset]?.at ?? 0) else {
            return
        }
        self.window.partRetried(id: offset, at: at, resumesAt: at + delay)
        self.armStallTimer(offset: offset, after: delay + self.stallTimeout)
        if let size = self.uploadingParts[offset]?.0 {
            self.armHardDeadline(offset: offset, size: size, after: delay)
        }
    }
    
    /// No answer for a while: the window shrinks. The part itself is not touched.
    private func armStallTimer(offset: Int64, after delay: Double) {
        self.partTimers.removeValue(forKey: offset)?.dispose()
        let timer = SignalKitTimer(timeout: delay, repeat: false, completion: { [weak self] in
            guard let self, self.uploadingParts[offset] != nil else {
                return
            }
            self.partTimers.removeValue(forKey: offset)
            self.window.partStalled(id: offset, at: self.now())
        }, queue: self.queue)
        self.partTimers[offset] = ActionDisposable {
            timer.invalidate()
        }
        timer.start()
    }
    
    private func cancelPartTimers() {
        for (_, timer) in self.partTimers {
            timer.dispose()
        }
        self.partTimers.removeAll()
        for (_, timer) in self.hardTimers {
            timer.dispose()
        }
        self.hardTimers.removeAll()
        self.partRequests.removeAll()
        self.reissuedParts.removeAll()
        self.issuedAt.removeAll()
    }
    
    private func checkNetwork(at: Double) {
        if self.networkIsInjected {
            return
        }
        let description = pendingFailureNetworkDescription()
        if description != self.lastNetworkDescription {
            self.lastNetworkDescription = description
            self.window.networkChanged(MultipartUploadManager.networkClass(description: description), at: at)
        }
    }
    
    /// The end of the upload, ok or not; logs one line (numbers and fixed tokens only) and reports the result.
    private func finish(_ result: MultipartIntermediateResult?) {
        self.cancelPartTimers()
        if !self.finishLogged {
            self.finishLogged = true
            let stats = self.window.stats
            let milliseconds = Int(max(0.0, self.now() - self.startedAt) * 1000.0)
            let endNetwork = self.networkIsInjected ? stats.endNetwork.rawValue : pendingFailureNetworkDescription()
            let line = "upload end ok=\(result != nil ? 1 : 0) parts=\(stats.parts) bytes=\(stats.bytes) ms=\(milliseconds) part=\(self.defaultPartSize) win=\(stats.minWindow)/\(stats.maxWindow)/\(self.window.window) retries=\(stats.retries) stalls=\(stats.stalls) fails=\(stats.failures) dec=\(stats.decreases) net=\(self.startNetworkName)>\(endNetwork)"
            if let finishLog = self.finishLog {
                finishLog(line)
            } else {
                pendingMessageFailureLog(line)
            }
        }
        self.completed(result)
    }
    
    private func readPart(resourceData: MultipartUploadData, offset: Int64, size: Int64) -> Data? {
        switch resourceData {
            case let .resourceData(data):
                guard let file = ManagedFile(queue: nil, path: data.path, mode: .read) else {
                    return nil
                }
                let _ = file.seek(position: offset)
                let partData = file.readData(count: Int(size))
                return partData.count == size ? partData : nil
            case let .data(data):
                if data.count >= offset + size {
                    return data.subdata(in: Int(offset) ..< Int(offset + size))
                } else {
                    return nil
                }
        }
    }
    
    private func uploadPendingHeaderParts(resourceData: MultipartUploadData) {
        while !self.pendingHeaderOffsets.isEmpty && self.uploadingParts.count < self.parallelParts {
            let partOffset = self.pendingHeaderOffsets.removeFirst()
            let partSize = min(resourceData.size - partOffset, self.defaultPartSize)
            guard let fileData = self.readPart(resourceData: resourceData, offset: partOffset, size: partSize) else {
                self.pendingHeaderOffsets.removeAll()
                self.finish(nil)
                return
            }
            let partData = self.state.transformHeader(data: fileData)
            var currentBigTotalParts: Int? = nil
            if self.bigParts {
                currentBigTotalParts = Int(resourceData.size / self.defaultPartSize) + (resourceData.size % self.defaultPartSize == 0 ? 0 : 1)
            }
            let part = self.uploadPart(UploadPart(fileId: self.fileId, index: Int(partOffset / self.defaultPartSize), data: partData, bigTotalParts: currentBigTotalParts, bigPart: self.bigParts, offset: partOffset, onRetry: self.retryNotice(offset: partOffset)))
            |> deliverOn(self.queue)
            self.partWillStart(offset: partOffset, size: partSize)
            let headerPartIndex = Int(partOffset / self.defaultPartSize)
            self.partRequests[partOffset] = PartRequest(signal: part, partIndex: headerPartIndex, isHeader: true)
            self.startPart(part, offset: partOffset, size: partSize, partIndex: headerPartIndex, isHeader: true)
        }
    }
}

enum MultipartUploadResult {
    case progress(Float)
    case inputFile(Api.InputFile)
    case inputSecretFile(Api.InputEncryptedFile, Int64, SecretFileEncryptionKey)
}

public enum MultipartUploadSource {
    case resource(MediaResourceReference)
    case data(Data)
    case custom(Signal<MediaResourceData, NoError>)
    case tempFile(TempBoxFile)
}

enum MultipartUploadError {
    case generic
}

func multipartUpload(network: Network, postbox: Postbox, source: MultipartUploadSource, encrypt: Bool, tag: MediaResourceFetchTag?, hintFileSize: Int64?, hintFileIsLarge: Bool, forceNoBigParts: Bool, useLargerParts: Bool = false, increaseParallelParts: Bool = false, useMultiplexedRequests: Bool = true, useCompression: Bool = false) -> Signal<MultipartUploadResult, MultipartUploadError> {
    enum UploadInterface {
        case download(Download)
        case multiplexed(manager: MultiplexedRequestManager, datacenterId: Int, consumerId: Int64)
    }
    
    let uploadInterface: Signal<UploadInterface, NoError>
    if useMultiplexedRequests {
        uploadInterface = .single(.multiplexed(manager: network.multiplexedRequestManager, datacenterId: network.datacenterId, consumerId: Int64.random(in: Int64.min ... Int64.max)))
    } else {
        uploadInterface = network.upload(tag: tag)
        |> map { download -> UploadInterface in
            return .download(download)
        }
    }
    
    return uploadInterface
    |> mapToSignalPromotingError { uploadInterface -> Signal<MultipartUploadResult, MultipartUploadError> in
        return Signal { [network] subscriber in
            var encryptionKey: SecretFileEncryptionKey?
            if encrypt {
                var aesKey = Data()
                aesKey.count = 32
                var aesIv = Data()
                aesIv.count = 32
                aesKey.withUnsafeMutableBytes { rawBytes -> Void in
                    let bytes = rawBytes.baseAddress!
                    arc4random_buf(bytes, 32)
                }
                aesIv.withUnsafeMutableBytes { rawBytes -> Void in
                    let bytes = rawBytes.baseAddress!
                    arc4random_buf(bytes, 32)
                }
                encryptionKey = SecretFileEncryptionKey(aesKey: aesKey, aesIv: aesIv)
            }
            
            let dataSignal: Signal<MultipartUploadData, NoError>
            let headerSize: () -> Int64
            let fetchedResource: Signal<Void, FetchResourceError>
            switch source {
                case let .resource(resource):
                    let resourceValue = resource.resource
                    headerSize = { Int64(resourceValue.headerSize) }
                    let resourceData = postbox.mediaBox.resourceData(resource.resource, option: .incremental(waitUntilFetchStatus: true))
                    if resourceValue.headerSize > 0 {
                        // A conversion output (video, audio, GIF) grows while it is written and rewrites only its
                        // header, which is uploaded last. The media box reports an unfinished file as empty, so the
                        // written prefix comes from its ranges: the upload runs while the conversion does.
                        dataSignal = combineLatest(resourceData, postbox.mediaBox.resourceRangesStatus(resource.resource))
                        |> map { data, ranges -> MultipartUploadData in
                            if data.complete {
                                return .resourceData(data)
                            }
                            var writtenPrefix: Int64 = 0
                            if let first = ranges.ranges.first, first.lowerBound == 0 {
                                writtenPrefix = first.upperBound
                            }
                            return .resourceData(MediaResourceData(path: data.path, offset: 0, size: writtenPrefix, complete: false))
                        }
                    } else {
                        dataSignal = resourceData |> map { MultipartUploadData.resourceData($0) }
                    }
                    fetchedResource = fetchedMediaResource(mediaBox: postbox.mediaBox, userLocation: .other, userContentType: .other, reference: resource)
                    |> map { _ in }
                case let .tempFile(file):
                    if let size = fileSize(file.path) {
                        dataSignal = .single(.resourceData(MediaResourceData(path: file.path, offset: 0, size: size, complete: true)))
                        headerSize = { 0 }
                        fetchedResource = .complete()
                    } else {
                        subscriber.putError(.generic)
                        return EmptyDisposable
                    }
                case let .data(data):
                    dataSignal = .single(.data(data))
                    headerSize = { 0 }
                    fetchedResource = .complete()
                case let .custom(signal):
                    headerSize = { 1024 }
                    dataSignal = signal
                    |> map { data in
                        print("**data \(data) \(data.complete)")
                        return MultipartUploadData.resourceData(data)
                    }
                    fetchedResource = .complete()
            }
            
            let onFloodWaitError: (String) -> Void = { [weak network] error in
                guard let network else {
                    return
                }
                if error.hasPrefix("FLOOD_PREMIUM_WAIT") {
                    network.addNetworkSpeedLimitedEvent(event: .upload)
                }
            }
            
            let manager = MultipartUploadManager(headerSize: headerSize, data: dataSignal, encryptionKey: encryptionKey, hintFileSize: hintFileSize, hintFileIsLarge: hintFileIsLarge, forceNoBigParts: forceNoBigParts, useLargerParts: useLargerParts, increaseParallelParts: increaseParallelParts, hardDeadlineAllowed: useMultiplexedRequests, uploadPart: { part in
                switch uploadInterface {
                case let .download(download):
                    return pendingUploadPartRetrying(download.uploadPart(fileId: part.fileId, index: part.index, data: part.data, asBigPart: part.bigPart, bigTotalParts: part.bigTotalParts, useCompression: useCompression, onFloodWaitError: onFloodWaitError), onRetry: part.onRetry.map { notify in { _, delay in notify(delay) } })
                case let .multiplexed(multiplexed, datacenterId, consumerId):
                    return pendingUploadPartRetrying(Download.uploadPart(multiplexedManager: multiplexed, datacenterId: datacenterId, consumerId: consumerId, tag: nil, fileId: part.fileId, index: part.index, data: part.data, asBigPart: part.bigPart, bigTotalParts: part.bigTotalParts, useCompression: useCompression, onFloodWaitError: onFloodWaitError), onRetry: part.onRetry.map { notify in { _, delay in notify(delay) } })
                }
            }, progress: { progress in
                subscriber.putNext(.progress(progress))
            }, completed: { result in
                if let result = result {
                    if let encryptionKey = encryptionKey {
                        let keyDigest = md5(encryptionKey.aesKey + encryptionKey.aesIv)
                        var fingerprint: Int32 = 0
                        keyDigest.withUnsafeBytes { rawBytes -> Void in
                            let bytes = rawBytes.baseAddress!.assumingMemoryBound(to: UInt8.self)
                            
                            withUnsafeMutableBytes(of: &fingerprint, { ptr -> Void in
                                let uintPtr = ptr.baseAddress!.assumingMemoryBound(to: UInt8.self)
                                uintPtr[0] = bytes[0] ^ bytes[4]
                                uintPtr[1] = bytes[1] ^ bytes[5]
                                uintPtr[2] = bytes[2] ^ bytes[6]
                                uintPtr[3] = bytes[3] ^ bytes[7]
                            })
                        }
                        if let _ = result.bigTotalParts {
                            let inputFile = Api.InputEncryptedFile.inputEncryptedFileBigUploaded(.init(id: result.id, parts: result.partCount, keyFingerprint: fingerprint))
                            subscriber.putNext(.inputSecretFile(inputFile, result.size, encryptionKey))
                        } else {
                            let inputFile = Api.InputEncryptedFile.inputEncryptedFileUploaded(.init(id: result.id, parts: result.partCount, md5Checksum: result.md5Digest, keyFingerprint: fingerprint))
                            subscriber.putNext(.inputSecretFile(inputFile, result.size, encryptionKey))
                        }
                    } else {
                        if let _ = result.bigTotalParts {
                            let inputFile = Api.InputFile.inputFileBig(.init(id: result.id, parts: result.partCount, name: "file.jpg"))
                            subscriber.putNext(.inputFile(inputFile))
                        } else {
                            let inputFile = Api.InputFile.inputFile(.init(id: result.id, parts: result.partCount, name: "file.jpg", md5Checksum: result.md5Digest))
                            subscriber.putNext(.inputFile(inputFile))
                        }
                    }
                    subscriber.putCompletion()
                } else {
                    subscriber.putError(.generic)
                }
            })

            manager.start()
            
            let fetchedResourceDisposable = fetchedResource.start(error: { _ in
                subscriber.putError(.generic)
            })
            
            return ActionDisposable {
                manager.cancel()
                fetchedResourceDisposable.dispose()
            }
        }
    }
}
