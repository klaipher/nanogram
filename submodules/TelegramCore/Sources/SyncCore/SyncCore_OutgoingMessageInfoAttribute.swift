import Foundation
import Postbox

public struct OutgoingMessageInfoFlags: OptionSet {
    public var rawValue: Int32
    
    public init() {
        self.rawValue = 0
    }
    
    public init(rawValue: Int32) {
        self.rawValue = rawValue
    }
    
    public static var transformedMedia = OutgoingMessageInfoFlags(rawValue: 1 << 0)
}

public class OutgoingMessageInfoAttribute: MessageAttribute {
    public let uniqueId: Int64
    public let flags: OutgoingMessageInfoFlags
    public let acknowledged: Bool
    public let correlationId: Int64?
    public let bubbleUpEmojiOrStickersets: [ItemCollectionId]
    public let partialReference: PartialMediaReference?
    public let sendErrorCode: String?
    
    public init(uniqueId: Int64, flags: OutgoingMessageInfoFlags, acknowledged: Bool, correlationId: Int64?, bubbleUpEmojiOrStickersets: [ItemCollectionId], partialReference: PartialMediaReference?, sendErrorCode: String? = nil) {
        self.uniqueId = uniqueId
        self.flags = flags
        self.acknowledged = acknowledged
        self.correlationId = correlationId
        self.bubbleUpEmojiOrStickersets = bubbleUpEmojiOrStickersets
        self.partialReference = partialReference
        self.sendErrorCode = sendErrorCode
    }
    
    required public init(decoder: PostboxDecoder) {
        self.uniqueId = decoder.decodeInt64ForKey("u", orElse: 0)
        self.flags = OutgoingMessageInfoFlags(rawValue: decoder.decodeInt32ForKey("f", orElse: 0))
        self.acknowledged = decoder.decodeInt32ForKey("ack", orElse: 0) != 0
        self.correlationId = decoder.decodeOptionalInt64ForKey("cid")
        self.sendErrorCode = decoder.decodeOptionalStringForKey("sendErrorCode")
        if let data = decoder.decodeDataForKey("bubbleUpEmojiOrStickersets") {
            self.bubbleUpEmojiOrStickersets = ItemCollectionId.decodeArrayFromBuffer(ReadBuffer(data: data))
        } else {
            self.bubbleUpEmojiOrStickersets = []
        }
        if let partialReference = decoder.decodeAnyObjectForKey("partialReference", decoder: { PartialMediaReference(decoder: $0) }) as? PartialMediaReference {
            self.partialReference = partialReference
        } else {
            self.partialReference = nil
        }
    }
    
    public func encode(_ encoder: PostboxEncoder) {
        encoder.encodeInt64(self.uniqueId, forKey: "u")
        encoder.encodeInt32(self.flags.rawValue, forKey: "f")
        encoder.encodeInt32(self.acknowledged ? 1 : 0, forKey: "ack")
        if let correlationId = self.correlationId {
            encoder.encodeInt64(correlationId, forKey: "cid")
        } else {
            encoder.encodeNil(forKey: "cid")
        }
        if let sendErrorCode = self.sendErrorCode {
            encoder.encodeString(sendErrorCode, forKey: "sendErrorCode")
        }
        let bubbleUpEmojiOrStickersetsBuffer = WriteBuffer()
        ItemCollectionId.encodeArrayToBuffer(self.bubbleUpEmojiOrStickersets, buffer: bubbleUpEmojiOrStickersetsBuffer)
        encoder.encodeData(bubbleUpEmojiOrStickersetsBuffer.makeData(), forKey: "bubbleUpEmojiOrStickersets")
        if let partialReference {
            encoder.encodeObjectWithEncoder(partialReference, encoder: partialReference.encode, forKey: "partialReference")
        } else {
            encoder.encodeNil(forKey: "partialReference")
        }
    }
    
    public func withUpdatedFlags(_ flags: OutgoingMessageInfoFlags) -> OutgoingMessageInfoAttribute {
        return OutgoingMessageInfoAttribute(uniqueId: self.uniqueId, flags: flags, acknowledged: self.acknowledged, correlationId: self.correlationId, bubbleUpEmojiOrStickersets: self.bubbleUpEmojiOrStickersets, partialReference: self.partialReference, sendErrorCode: self.sendErrorCode)
    }
    
    func withSendErrorCode(_ code: String) -> OutgoingMessageInfoAttribute {
        return OutgoingMessageInfoAttribute(uniqueId: self.uniqueId, flags: self.flags, acknowledged: self.acknowledged, correlationId: self.correlationId, bubbleUpEmojiOrStickersets: self.bubbleUpEmojiOrStickersets, partialReference: self.partialReference, sendErrorCode: code)
    }

    public func withUpdatedAcknowledged(_ acknowledged: Bool) -> OutgoingMessageInfoAttribute {
        return OutgoingMessageInfoAttribute(uniqueId: self.uniqueId, flags: self.flags, acknowledged: acknowledged, correlationId: self.correlationId, bubbleUpEmojiOrStickersets: self.bubbleUpEmojiOrStickersets, partialReference: self.partialReference, sendErrorCode: self.sendErrorCode)
    }
}
