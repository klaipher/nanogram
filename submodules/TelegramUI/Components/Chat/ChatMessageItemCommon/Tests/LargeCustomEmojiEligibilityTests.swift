import XCTest
import QuartzCore
import Postbox
import TelegramCore
import Emoji
import ChatMessageItemCommon

/// `messageIsEligibleForLargeCustomEmoji` runs for every media-less message on every history update, on main.
/// It used to copy the whole text twice (stripping spaces and newlines) before looking at the entities, which
/// rule out almost every message: up to 174 us per 4k-character post.
final class LargeCustomEmojiEligibilityTests: XCTestCase {
    private let peer = makeGroupChannel(id: 7)

    // The function as it was before the entity-first order.
    private func reference(_ message: EngineMessage) -> Bool {
        let text = message.text.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: " ", with: "")
        guard !text.isEmpty && text.containsOnlyEmoji else {
            return false
        }
        let entities = message.textEntitiesAttribute?.entities ?? []
        guard entities.count > 0 else {
            return false
        }
        for entity in entities {
            if case let .CustomEmoji(_, fileId) = entity.type {
                if let _ = message.associatedMedia[EngineMedia.Id(namespace: Namespaces.Media.CloudFile, id: fileId)] as? TelegramMediaFile {
                } else {
                    return false
                }
            } else {
                return false
            }
        }
        return true
    }

    private func file(_ id: Int64) -> TelegramMediaFile {
        return TelegramMediaFile(fileId: MediaId(namespace: Namespaces.Media.CloudFile, id: id), partialReference: nil, resource: EmptyMediaResource(), previewRepresentations: [], videoThumbnails: [], immediateThumbnailData: nil, mimeType: "application/x-tgsticker", size: nil, attributes: [], alternativeRepresentations: [])
    }

    private func message(_ text: String, entities: [MessageTextEntityType]?, files: [Int64] = []) -> EngineMessage {
        var attributes: [MessageAttribute] = []
        if let entities {
            let utf16Count = (text as NSString).length
            attributes.append(TextEntitiesMessageAttribute(entities: entities.map { MessageTextEntity(range: 0 ..< max(1, utf16Count), type: $0) }))
        }
        var associatedMedia: [MediaId: Media] = [:]
        for id in files {
            associatedMedia[MediaId(namespace: Namespaces.Media.CloudFile, id: id)] = self.file(id)
        }
        let base = makeMessage(peer: self.peer, author: nil, attributes: attributes)
        let message = Message(stableId: base.stableId, stableVersion: 0, id: base.id, globallyUniqueId: nil, groupingKey: nil, groupInfo: nil, threadId: nil, timestamp: base.timestamp, flags: base.flags, tags: base.tags, globalTags: base.globalTags, localTags: base.localTags, customTags: [], forwardInfo: nil, author: nil, text: text, attributes: attributes, media: [], peers: base.peers, associatedMessages: SimpleDictionary(), associatedMessageIds: [], associatedMedia: associatedMedia, associatedThreadInfo: nil, associatedStories: [:])
        return EngineMessage(message)
    }

    private var corpus: [EngineMessage] {
        let texts = ["", " ", "\n", "😀", "😀😀", " 😀 \n😀", "a😀", "😀 a", "👨‍👩‍👧", "🇺🇸", "🇺 🇸", "😀 \u{301}", "👨 \u{200D}👩", "😀\r\n😀", "\u{301}", "#", "1️⃣", "©", "😀\t😀", String(repeating: "Привет мир ", count: 200), String(repeating: "😀", count: 50)]
        let entitySets: [([MessageTextEntityType]?, [Int64])] = [
            (nil, []),
            ([], []),
            ([.Bold], []),
            ([.CustomEmoji(stickerPack: nil, fileId: 1)], [1]),
            ([.CustomEmoji(stickerPack: nil, fileId: 1)], []),
            ([.CustomEmoji(stickerPack: nil, fileId: 1), .CustomEmoji(stickerPack: nil, fileId: 2)], [1, 2]),
            ([.CustomEmoji(stickerPack: nil, fileId: 1), .CustomEmoji(stickerPack: nil, fileId: 2)], [1]),
            ([.CustomEmoji(stickerPack: nil, fileId: 1), .Bold], [1]),
            ([.Url], [1]),
        ]
        var result: [EngineMessage] = []
        for text in texts {
            for (entities, files) in entitySets {
                result.append(self.message(text, entities: entities, files: files))
            }
        }
        return result
    }

    func testSameAnswerAsBefore() {
        var trueCount = 0
        for message in self.corpus {
            let expected = self.reference(message)
            XCTAssertEqual(messageIsEligibleForLargeCustomEmoji(message), expected, "\(message.text.debugDescription) \(String(describing: message.textEntitiesAttribute?.entities))")
            if expected {
                trueCount += 1
            }
        }
        XCTAssertGreaterThan(trueCount, 10)
    }

    func testSingleCharacterMatchesCountOfOne() {
        for text in ["", "a", "ab", "😀", "😀😀", "👨‍👩‍👧", "🇺🇸", "é", "e\u{301}", "\r\n", "\n\n", String(repeating: "я", count: 4000)] {
            XCTAssertEqual(stringIsSingleCharacter(text), text.count == 1, text.debugDescription)
        }
    }

    // Benchmark: about 90 long channel posts (no custom-emoji entities) per history update.
    func testBenchmarkLongPostsWithoutCustomEmoji() {
        let posts = (0 ..< 90).map { index in
            self.message(String(repeating: "Съешь же ещё этих мягких французских булок, да выпей чаю. ", count: 70), entities: index % 2 == 0 ? nil : [.Bold, .Url])
        }
        func time(_ body: (EngineMessage) -> Bool) -> Double {
            var best = Double.infinity
            for _ in 0 ..< 5 {
                let start = CACurrentMediaTime()
                for post in posts {
                    _ = body(post)
                }
                best = min(best, CACurrentMediaTime() - start)
            }
            return best * 1000.0
        }
        // Both checks ChatHistoryEntriesForView runs per media-less message: the custom-emoji check and `text.count == 1`.
        let before = time { message in
            let eligible = self.reference(message)
            return message.text.count == 1 || eligible
        }
        let after = time { message in
            let eligible = messageIsEligibleForLargeCustomEmoji(message)
            return stringIsSingleCharacter(message.text) || eligible
        }
        print("BENCH large custom emoji check, 90 posts of 4k Cyrillic chars: before \(String(format: "%.2f", before)) ms, after \(String(format: "%.3f", after)) ms")
        XCTAssertLessThan(after, before / 10.0)
    }
}
