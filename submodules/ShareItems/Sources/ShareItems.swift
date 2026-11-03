import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore
import MtProtoKit
import Display
import AccountContext
import Pdf
import LocalMediaResources
import AVFoundation
import LegacyComponents
import ShareItemsImpl
import UIKit
import SSignalKit

public enum UnpreparedShareItemContent {
    case contact(DeviceContactExtendedData)
}

public enum PreparedShareItemContent {
    case text(String)
    case media(StandaloneUploadMediaResult)
}

public enum PreparedShareItem {
    case preparing(Bool)
    case progress(Float)
    case userInteractionRequired(UnpreparedShareItemContent)
    case done(PreparedShareItemContent)
}

public enum PreparedShareItems {
    case preparing(Bool)
    case progress(Float)
    case userInteractionRequired([UnpreparedShareItemContent])
    case done([PreparedShareItemContent])
}

private func scalePhotoImage(_ image: UIImage, dimensions: CGSize) -> UIImage? {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1.0
    let renderer = UIGraphicsImageRenderer(size: dimensions, format: format)
    return renderer.image { _ in
        image.draw(in: CGRect(origin: .zero, size: dimensions))
    }
}

public enum PreparedShareItemError {
    case generic
    case fileTooBig(Int64)
}

/// The long side of a shared photo: 1280, or 2560 for "Send in HD".
public func shareItemImageMaxPixelSize(highQuality: Bool) -> CGFloat {
    return highQuality ? 2560.0 : 1280.0
}

private func preparedShareItem(postbox: Postbox, network: Network, to peerId: PeerId, value: [String: Any], highQuality: Bool) -> Signal<PreparedShareItem, PreparedShareItemError> {
    let maxImagePixelSize = (value["maxImagePixelSize"] as? NSNumber).flatMap { CGFloat($0.doubleValue) } ?? shareItemImageMaxPixelSize(highQuality: highQuality)
    if let imageData = value["scaledImageData"] as? Data, let dimensions = value["scaledImageDimensions"] as? NSValue {
        let diminsionsSize = dimensions.cgSizeValue
        return .single(.preparing(false))
        |> then(
            standaloneUploadedImage(postbox: postbox, network: network, peerId: peerId, text: "", source: .data(imageData), dimensions: PixelDimensions(width: Int32(diminsionsSize.width), height: Int32(diminsionsSize.height)))
            |> mapError { _ -> PreparedShareItemError in
                return .generic
            }
            |> mapToSignal { event -> Signal<PreparedShareItem, PreparedShareItemError> in
                switch event {
                    case let .progress(value):
                        return .single(.progress(value))
                    case let .result(media):
                        return .single(.done(.media(media)))
                }
            }
        )
    } else if let image = value["image"] as? UIImage {
        let nativeImageSize = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let dimensions = nativeImageSize.fitted(CGSize(width: maxImagePixelSize, height: maxImagePixelSize))
        if let scaledImage = scalePhotoImage(image, dimensions: dimensions), let imageData = scaledImage.jpegData(compressionQuality: 0.52) {
            return .single(.preparing(false))
            |> then(
                standaloneUploadedImage(postbox: postbox, network: network, peerId: peerId, text: "", source: .data(imageData), dimensions: PixelDimensions(width: Int32(dimensions.width), height: Int32(dimensions.height)))
                |> mapError { _ -> PreparedShareItemError in
                    return .generic
                }
                |> mapToSignal { event -> Signal<PreparedShareItem, PreparedShareItemError> in
                    switch event {
                        case let .progress(value):
                            return .single(.progress(value))
                        case let .result(media):
                            return .single(.done(.media(media)))
                    }
                }
            )
        } else {
            return .fail(.generic)
        }
    } else if let asset = value["video"] as? AVURLAsset {
        var flags: TelegramMediaVideoFlags = [.supportsStreaming]
        let sendAsInstantRoundVideo = value["isRoundMessage"] as? Bool ?? false
        var adjustments: TGVideoEditAdjustments? = nil
        if sendAsInstantRoundVideo {
            flags.insert(.instantRoundVideo)
            
            if let width = value["width"] as? CGFloat, let height = value["height"] as? CGFloat {
                let size = CGSize(width: width, height: height)
                
                var cropRect = CGRect(origin: CGPoint(), size: size)
                if abs(width - height) < CGFloat.ulpOfOne {
                    cropRect = cropRect.insetBy(dx: 13.0, dy: 13.0)
                    cropRect = cropRect.offsetBy(dx: 2.0, dy: 3.0)
                } else {
                    let shortestSide = min(size.width, size.height)
                    cropRect = CGRect(x: (size.width - shortestSide) / 2.0, y: (size.height - shortestSide) / 2.0, width: shortestSide, height: shortestSide)
                }

                adjustments = TGVideoEditAdjustments(originalSize: size, cropRect: cropRect, cropOrientation: .up, cropRotation: 0.0, cropLockedAspectRatio: 1.0, cropMirrored: false, trimStartValue: 0.0, trimEndValue: 0.0, toolValues: nil, paintingData: nil, sendAsGif: false, preset: TGMediaVideoConversionPresetVideoMessage)
            }
        }
        func loadValues(_ avAsset: AVURLAsset) -> Signal<AVURLAsset, PreparedShareItemError> {
            return Signal { subscriber in
                avAsset.loadValuesAsynchronously(forKeys: ["tracks", "duration", "playable"]) {
                    var error: NSError?
                    if avAsset.statusOfValue(forKey: "duration", error: &error) == .failed {
                        subscriber.putError(.generic)
                    } else {
                        subscriber.putNext(avAsset)
                        subscriber.putCompletion()
                    }
                }
                return ActionDisposable {
                    avAsset.cancelLoading()
                }
            }
        }
        
        func getThumbnail(_ avAsset: AVURLAsset) -> Signal<UIImage?, NoError> {
            return Signal { subscriber in
                let imageGenerator = AVAssetImageGenerator(asset: asset)
                imageGenerator.appliesPreferredTrackTransform = true
                imageGenerator.maximumSize = CGSize(width: 640, height: 640)
                imageGenerator.generateCGImagesAsynchronously(forTimes: [NSValue(time: CMTime(seconds: 0, preferredTimescale: CMTimeScale(30.0)))]) { _, image, _, _, _ in
                    subscriber.putNext(image.flatMap { UIImage(cgImage: $0) })
                    subscriber.putCompletion()
                }
                return ActionDisposable {
                    imageGenerator.cancelAllCGImageGeneration()
                }
            }
            
        }
        
        return .single(.preparing(true))
        |> then(
            loadValues(asset)
            |> mapToSignal { asset -> Signal<PreparedShareItem, PreparedShareItemError> in
                return getThumbnail(asset)
                |> castError(PreparedShareItemError.self)
                |> mapToSignal { thumbnail -> Signal<PreparedShareItem, PreparedShareItemError> in
                    // Read once the values above have loaded, never on the item provider's queue.
                    var finalDuration: Double = CMTimeGetSeconds(asset.duration)
                    let preset = adjustments?.preset ?? TGMediaVideoConversionPresetCompressedMedium
                    let finalDimensions = TGMediaVideoConverter.dimensions(for: asset.originalSize, adjustments: adjustments, preset: preset)
                    
                    var resourceAdjustments: VideoMediaResourceAdjustments?
                    if let adjustments = adjustments {
                        if adjustments.trimApplied() {
                            finalDuration = adjustments.trimEndValue - adjustments.trimStartValue
                        }
                        
                        if let dict = adjustments.dictionary(), let data = try? NSKeyedArchiver.archivedData(withRootObject: dict, requiringSecureCoding: false) {
                            let adjustmentsData = MemoryBuffer(data: data)
                            let digest = MemoryBuffer(data: adjustmentsData.md5Digest())
                            resourceAdjustments = VideoMediaResourceAdjustments(data: adjustmentsData, digest: digest, isStory: false)
                        }
                    }
                    
                    let estimatedSize = TGMediaVideoConverter.estimatedSize(for: preset, duration: finalDuration, hasAudio: true)
                    
                    let thumbnailData = thumbnail?.jpegData(compressionQuality: 0.6)
                    
                    let resource = LocalFileVideoMediaResource(randomId: Int64.random(in: Int64.min ... Int64.max), path: asset.url.path, adjustments: resourceAdjustments)
                    return standaloneUploadedFile(postbox: postbox, network: network, peerId: peerId, text: "", source: .resource(.standalone(resource: resource)), thumbnailData: thumbnailData, mimeType: "video/mp4", attributes: [.Video(duration: finalDuration, size: PixelDimensions(width: Int32(finalDimensions.width), height: Int32(finalDimensions.height)), flags: flags, preloadSize: nil, coverTime: 0.0, videoCodec: nil)], hintFileIsLarge: estimatedSize > 10 * 1024 * 1024)
                    |> mapError { _ -> PreparedShareItemError in
                        return .generic
                    }
                    |> mapToSignal { event -> Signal<PreparedShareItem, PreparedShareItemError> in
                        switch event {
                            case let .progress(value):
                                return .single(.progress(value))
                            case let .result(media):
                                return .single(.done(.media(media)))
                        }
                    }
                }
            }
        )
    } else if let data = value["data"] as? Data {
        let fileName = value["fileName"] as? String
        let mimeType = (value["mimeType"] as? String) ?? "application/octet-stream"
        
        var treatAsFile = false
        if let boolValue = value["treatAsFile"] as? Bool, boolValue {
            treatAsFile = true
        }
        
        if !treatAsFile, let image = UIImage(data: data) {
            var isGif = false
            if data.count > 4 {
                data.withUnsafeBytes { buffer -> Void in
                    guard let bytes = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                        return
                    }
                    if bytes.advanced(by: 0).pointee == 71 // G
                    && bytes.advanced(by: 1).pointee == 73 // I
                    && bytes.advanced(by: 2).pointee == 70 // F
                    && bytes.advanced(by: 3).pointee == 56 // 8
                    {
                        isGif = true
                    }
                }
            }
            if isGif {
                #if DEBUG
                let signal = SSignal(generator: { _ in
                    return SBlockDisposable(block: {})
                })
                let _ = signal.start(next: nil, error: nil, completed: nil)
                #endif
                
                let convertedData = Signal<(Data, CGSize, Double, Bool), NoError> { subscriber in
                    let disposable = MetaDisposable()
                    let signalDisposable = TGGifConverter.convertGif(toMp4: data).start(next: { next in
                        if let result = next as? NSDictionary, let path = result["path"] as? String, let convertedData = try? Data(contentsOf: URL(fileURLWithPath: path)), let duration = result["duration"] as? Double {
                            subscriber.putNext((convertedData, image.size, duration, true))
                            subscriber.putCompletion()
                        }
                    }, error: { _ in
                        subscriber.putNext((data, image.size, 0, false))
                        subscriber.putCompletion()
                    }, completed: nil)
                    disposable.set(ActionDisposable {
                        signalDisposable?.dispose()
                    })
                    return disposable
                }
                
                return .single(.preparing(true))
                |> then(
                    convertedData
                    |> castError(PreparedShareItemError.self)
                    |> mapToSignal { data, dimensions, duration, converted in
                        var attributes: [TelegramMediaFileAttribute] = []
                        let mimeType: String
                        if converted {
                            mimeType = "video/mp4"
                            attributes = [.Video(duration: duration, size: PixelDimensions(width: Int32(dimensions.width), height: Int32(dimensions.height)), flags: [.supportsStreaming], preloadSize: nil, coverTime: nil, videoCodec: nil), .Animated, .FileName(fileName: "animation.mp4")]
                        } else {
                            mimeType = "animation/gif"
                            attributes = [.ImageSize(size: PixelDimensions(width: Int32(dimensions.width), height: Int32(dimensions.height))), .Animated, .FileName(fileName: fileName ?? "animation.gif")]
                        }
                        return standaloneUploadedFile(postbox: postbox, network: network, peerId: peerId, text: "", source: .data(data), mimeType: mimeType, attributes: attributes, hintFileIsLarge: data.count > 10 * 1024 * 1024)
                        |> mapError { _ -> PreparedShareItemError in
                            return .generic
                        }
                        |> mapToSignal { event -> Signal<PreparedShareItem, PreparedShareItemError> in
                            switch event {
                                case let .progress(value):
                                    return .single(.progress(value))
                                case let .result(media):
                                    return .single(.done(.media(media)))
                            }
                        }
                    }
                )
            } else {
                // Downsampled by ImageIO: drawing the UIImage decoded the whole image first
                // (~195 MB for a 48 MP photo), more than the extension may use.
                guard let scaled = TGItemProviderSignals.scaledJpegImage(with: data, maxPixelSize: maxImagePixelSize), let imageData = scaled["scaledImageData"] as? Data, let scaledDimensions = (scaled["scaledImageDimensions"] as? NSValue)?.cgSizeValue else {
                    return .fail(.generic)
                }
                return .single(.preparing(false))
                |> then(
                    standaloneUploadedImage(postbox: postbox, network: network, peerId: peerId, text: "", source: .data(imageData), dimensions: PixelDimensions(width: Int32(scaledDimensions.width), height: Int32(scaledDimensions.height)))
                    |> mapError { _ -> PreparedShareItemError in
                        return .generic
                    }
                    |> mapToSignal { event -> Signal<PreparedShareItem, PreparedShareItemError> in
                        switch event {
                            case let .progress(value):
                                return .single(.progress(value))
                            case let .result(media):
                                return .single(.done(.media(media)))
                        }
                    }
                )
            }
        } else {
            var thumbnailData: Data?
            if mimeType == "application/pdf", let image = generatePdfPreviewImage(data: data, size: CGSize(width: 256.0, height: 256.0)), let jpegData = image.jpegData(compressionQuality: 0.5) {
                thumbnailData = jpegData
            }
            
            let long = data.count > Int32(1.5 * 1024 * 1024)
            return .single(.preparing(long))
            |> then(
                standaloneUploadedFile(postbox: postbox, network: network, peerId: peerId, text: "", source: .data(data), thumbnailData: thumbnailData, mimeType: mimeType, attributes: [.FileName(fileName: fileName ?? "file")], hintFileIsLarge: data.count > 10 * 1024 * 1024)
                |> mapError { _ -> PreparedShareItemError in
                    return .generic
                }
                |> mapToSignal { event -> Signal<PreparedShareItem, PreparedShareItemError> in
                    switch event {
                        case let .progress(value):
                            return .single(.progress(value))
                        case let .result(media):
                            return .single(.done(.media(media)))
                    }
                }
            )
        }
    } else if let url = value["audio"] as? URL {
        if let audioData = try? Data(contentsOf: url, options: [.mappedIfSafe]) {
            let fileName = url.lastPathComponent
            let duration = (value["duration"] as? NSNumber)?.doubleValue ?? 0.0
            let isVoice = ((value["isVoice"] as? NSNumber)?.boolValue ?? false)
            let title = value["title"] as? String
            let artist = value["artist"] as? String
            let mimeType = value["mimeType"] as? String ?? "audio/ogg"
            
            var waveform: MemoryBuffer?
            if let waveformData = TGItemProviderSignals.audioWaveform(url) {
                waveform = MemoryBuffer(data: waveformData)
            }
            
            let long = audioData.count > Int32(1.5 * 1024 * 1024)
            return .single(.preparing(long))
            |> then(
                standaloneUploadedFile(postbox: postbox, network: network, peerId: peerId, text: "", source: .data(audioData), mimeType: mimeType, attributes: [.Audio(isVoice: isVoice, duration: Int(duration), title: title, performer: artist, waveform: waveform?.makeData()), .FileName(fileName: fileName)], hintFileIsLarge: audioData.count > 10 * 1024 * 1024)
                |> mapError { _ -> PreparedShareItemError in
                    return .generic
                }
                |> mapToSignal { event -> Signal<PreparedShareItem, PreparedShareItemError> in
                    switch event {
                        case let .progress(value):
                            return .single(.progress(value))
                        case let .result(media):
                            return .single(.done(.media(media)))
                    }
                }
            )
        } else {
            return .fail(.generic)
        }
    } else if let text = value["text"] as? String {
        return .single(.preparing(false))
        |> then(
            .single(.done(.text(text)))
        )
    } else if let url = value["url"] as? URL {
        if TGShareLocationSignals.isLocationURL(url) {
            return Signal<PreparedShareItem, PreparedShareItemError> { subscriber in
                subscriber.putNext(.preparing(false))
                let disposable = TGShareLocationSignals.locationMessageContent(for: url).start(next: { value in
                    if let value = value as? TGShareLocationResult {
                        if let title = value.title {
                            subscriber.putNext(.done(.media(.media(.standalone(media: TelegramMediaMap(latitude: value.latitude, longitude: value.longitude, heading: nil, accuracyRadius: nil, venue: MapVenue(title: title, address: value.address, provider: value.provider, id: value.venueId, type: value.venueType), liveBroadcastingTimeout: nil, liveProximityNotificationRadius: nil))))))
                        } else {
                            subscriber.putNext(.done(.media(.media(.standalone(media: TelegramMediaMap(latitude: value.latitude, longitude: value.longitude, heading: nil, accuracyRadius: nil, venue: nil, liveBroadcastingTimeout: nil, liveProximityNotificationRadius: nil))))))
                        }
                        subscriber.putCompletion()
                    } else if let value = value as? String {
                        subscriber.putNext(.done(.text(value)))
                        subscriber.putCompletion()
                    }
                })
                return ActionDisposable {
                    disposable?.dispose()
                }
            }
        } else {
            return .single(.preparing(false))
            |> then(
                .single(.done(.text(url.absoluteString)))
            )
        }
    } else if let vcard = value["contact"] as? Data, let contactData = DeviceContactExtendedData(vcard: vcard) {
        return .single(.userInteractionRequired(.contact(contactData)))
    } else {
        return .fail(.generic)
    }
}

/// How many shared items are prepared and uploaded at once. Each one can be a transcode, inside
/// an extension with a fixed memory limit.
public let maxConcurrentPreparedShareItems = 3

/// The item dictionaries from `TGItemProviderSignals`, loaded one after another. A provider that
/// fails, or completes without an item, fails the whole share with `.generic`: the sheet shows
/// its error instead of preparing forever.
public func shareItemDictionaries(dataItems: [MTSignal]) -> Signal<[[String: Any]], PreparedShareItemError> {
    var dataSignals: Signal<[String: Any], PreparedShareItemError> = .complete()
    for dataItem in dataItems {
        let wrappedSignal: Signal<[String: Any], PreparedShareItemError> = Signal { subscriber in
            let receivedValue = Atomic<Bool>(value: false)
            let disposable = dataItem.start(next: { value in
                if let value = value as? [String: Any] {
                    let _ = receivedValue.swap(true)
                    subscriber.putNext(value)
                } else {
                    subscriber.putError(.generic)
                }
            }, error: { _ in
                subscriber.putError(.generic)
            }, completed: {
                if receivedValue.with({ $0 }) {
                    subscriber.putCompletion()
                } else {
                    subscriber.putError(.generic)
                }
            })
            return ActionDisposable {
                disposable?.dispose()
            }
        }
        dataSignals = dataSignals
        |> then(
            wrappedSignal
            |> take(1)
        )
    }
    
    return dataSignals
    |> map { [$0] }
    |> reduceLeft(value: [[String: Any]](), f: { list, rest in
        return list + rest
    })
}

/// `combineLatest` that runs at most `maxConcurrent` of `signals` at a time, in order; an item
/// not started yet, or started without a value yet, reads as `pendingValue`. Emits on every
/// value, completes when every signal has, and fails with the first error.
public func combineLatestLimitingConcurrency<T, E>(_ signals: [Signal<T, E>], pendingValue: T, maxConcurrent: Int) -> Signal<[T], E> {
    if signals.isEmpty {
        return .single([])
    }
    return Signal { subscriber in
        let queue = Queue()
        let disposables = DisposableSet()
        var values = Array(repeating: pendingValue, count: signals.count)
        var nextIndex = 0
        var running = 0
        var completedCount = 0
        var finished = false
        
        func startNext() {
            while !finished && running < max(1, maxConcurrent) && nextIndex < signals.count {
                let index = nextIndex
                nextIndex += 1
                running += 1
                disposables.add((signals[index] |> deliverOn(queue)).start(next: { value in
                    if finished {
                        return
                    }
                    values[index] = value
                    subscriber.putNext(values)
                }, error: { error in
                    if finished {
                        return
                    }
                    finished = true
                    subscriber.putError(error)
                }, completed: {
                    if finished {
                        return
                    }
                    running -= 1
                    completedCount += 1
                    if completedCount == signals.count {
                        finished = true
                        subscriber.putCompletion()
                    } else {
                        startNext()
                    }
                }))
            }
        }
        
        queue.async {
            startNext()
        }
        
        return ActionDisposable {
            queue.async {
                finished = true
            }
            disposables.dispose()
        }
    }
}

public func preparedShareItems(postbox: Postbox, network: Network, to peerId: PeerId, dataItems: [MTSignal], highQuality: Bool = false) -> Signal<PreparedShareItems, PreparedShareItemError> {
    let shareItems = shareItemDictionaries(dataItems: dataItems)
    |> mapToSignal { items -> Signal<[PreparedShareItem], PreparedShareItemError> in
        return combineLatestLimitingConcurrency(items.map {
            preparedShareItem(postbox: postbox, network: network, to: peerId, value: $0, highQuality: highQuality)
        }, pendingValue: .progress(0.0), maxConcurrent: maxConcurrentPreparedShareItems)
    }
        
    return shareItems
    |> map { items -> PreparedShareItems in
        var result: [PreparedShareItemContent] = []
        var progresses: [Float] = []
        for item in items {
            switch item {
            case let .preparing(long):
                return .preparing(long)
            case let .progress(value):
                progresses.append(value)
            case let .userInteractionRequired(value):
                return .userInteractionRequired([value])
            case let .done(content):
                result.append(content)
                progresses.append(1.0)
            }
        }
        if result.count == items.count {
            return .done(result)
        } else {
            let value = progresses.reduce(0.0, +) / Float(progresses.count)
            return .progress(value)
        }
    }
    |> distinctUntilChanged(isEqual: { lhs, rhs in
        if case .preparing = lhs, case .preparing = rhs {
            return true
        } else {
            return false
        }
    })
}

public func sentShareItems(accountPeerId: PeerId, postbox: Postbox, network: Network, stateManager: AccountStateManager, auxiliaryMethods: AccountAuxiliaryMethods, to peerIds: [PeerId], threadIds: [PeerId: Int64], requireStars: [PeerId: StarsAmount], items: [PreparedShareItemContent], silently: Bool, additionalText: String) -> Signal<Float, Void> {
    var messages: [StandaloneSendEnqueueMessage] = []
    var groupingKey: Int64?
    var mediaTypes: (photo: Int, video: Int, music: Int, other: Int) = (0, 0, 0, 0)
    if items.count > 1 {
        for item in items {
            if case let .media(result) = item, case let .media(media) = result {
                if media.media is TelegramMediaImage {
                    mediaTypes.photo += 1
                } else if let media = media.media as? TelegramMediaFile {
                    if media.isVideo {
                        mediaTypes.video += 1
                    } else if media.isVoice || media.isAnimated || media.isSticker {
                        mediaTypes = (0, 0, 0, 0)
                        break
                    } else if media.isMusic {
                        mediaTypes.music += 1
                    } else if let fileName = media.fileName?.lowercased(), fileName.hasPrefix(".mp3") || fileName.hasPrefix("m4a") {
                        mediaTypes.music += 1
                    } else {
                        mediaTypes.other += 1
                    }
                } else {
                    mediaTypes = (0, 0, 0, 0)
                    break
                }
            }
        }
    }
    
    if ((mediaTypes.photo + mediaTypes.video) > 1) && (mediaTypes.music == 0 && mediaTypes.other == 0) {
        groupingKey = Int64.random(in: Int64.min ... Int64.max)
    } else if ((mediaTypes.photo + mediaTypes.video) == 0) && ((mediaTypes.music > 1 && mediaTypes.other == 0) || (mediaTypes.music == 0 && mediaTypes.other > 1)) {
        groupingKey = Int64.random(in: Int64.min ... Int64.max)
    }
    
    var mediaMessageCount = 0
    var consumedText = false
    var captionAssigned = false
    for item in items {
        switch item {
        case let .text(text):
            var message = StandaloneSendEnqueueMessage(
                content: .text(text: StandaloneSendEnqueueMessage.Text(
                    string: text,
                    entities: []
                )),
                replyToMessageId: nil
            )
            message.isSilent = silently
            messages.append(message)
        case let .media(media):
            switch media {
            case let .media(reference):
                let captionText: String
                if !captionAssigned {
                    if let file = reference.media as? TelegramMediaFile, file.isInstantVideo {
                        captionText = ""
                    } else {
                        captionText = additionalText
                        captionAssigned = true
                    }
                } else {
                    captionText = ""
                }
                var message = StandaloneSendEnqueueMessage(
                    content: .arbitraryMedia(
                        media: reference,
                        text: StandaloneSendEnqueueMessage.Text(
                            string: captionText,
                            entities: []
                        )
                    ),
                    replyToMessageId: nil
                )
                consumedText = true
                message.isSilent = silently
                message.groupingKey = groupingKey
                messages.append(message)
                mediaMessageCount += 1
            }
            if let _ = groupingKey, mediaMessageCount % 10 == 0 {
                groupingKey = Int64.random(in: Int64.min ... Int64.max)
            }
        }
    }
    
    if !consumedText && !additionalText.isEmpty {
        var message = StandaloneSendEnqueueMessage(
            content: .text(text: StandaloneSendEnqueueMessage.Text(
                string: additionalText,
                entities: []
            )),
            replyToMessageId: nil
        )
        message.isSilent = silently
        messages.append(message)
    }
    
    var peerSignals: Signal<Float, StandaloneSendMessagesError> = .single(0.0)
    for peerId in peerIds {
        var peerMessages = messages
        if let amount = requireStars[peerId] {
            var updatedMessages: [StandaloneSendEnqueueMessage] = []
            for message in peerMessages {
                var message = message
                message.sendPaidMessageStars = amount
                updatedMessages.append(message)
            }
            peerMessages = updatedMessages
        }
        peerSignals = peerSignals |> then(standaloneSendEnqueueMessages(
            accountPeerId: accountPeerId,
            postbox: postbox,
            network: network,
            stateManager: stateManager,
            auxiliaryMethods: auxiliaryMethods,
            peerId: peerId,
            threadId: threadIds[peerId],
            messages: peerMessages
        )
        |> mapToSignal { status -> Signal<Float, StandaloneSendMessagesError> in
            switch status {
            case let .progress(progress):
                //return .single(progress)
                let _ = progress
                return .complete()
            case .done:
                return .complete()
            }
        })
    }
    return peerSignals
    |> mapError { _ -> Void in
        return Void()
    }
}
