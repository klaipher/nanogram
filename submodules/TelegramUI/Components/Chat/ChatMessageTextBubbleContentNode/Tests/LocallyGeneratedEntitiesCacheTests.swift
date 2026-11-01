import XCTest
import QuartzCore
import TelegramCore
import TextFormat
@testable import ChatMessageTextBubbleContentNode

/// Phone-number and timecode detection runs in a text bubble's layout, on the main thread when the
/// CoreList chat backend lays a row out. CoreList builds a fresh node for a row that scrolls back into
/// the window, so the node's own cache is gone and the detector ran again for every re-entry.
final class LocallyGeneratedEntitiesCacheTests: XCTestCase {
    private let texts: [String] = [
        "Call me at +1 (415) 555-0132 tomorrow after 10:30, or at 020 7946 0958 if that does not work.",
        "Meeting moved to 14:45. The dial-in is +44 20 7946 0000, PIN 4417 #",
        "See 1:02:33 for the goal and 0:45 for the start of the second half",
        "Plain text with no digits at all, which should be cheap either way."
    ]

    func test_cachedResultIsTheDetectorsResult() {
        let cache = LocallyGeneratedEntitiesCache(capacity: 16)
        for text in self.texts {
            for (types, duration) in [(EnabledEntityTypes.all, nil as Double?), (EnabledEntityTypes.all.union(.timecode), 3600.0)] {
                let direct = addLocallyGeneratedEntities(text, enabledTypes: types, entities: [], mediaDuration: duration)
                let first = cache.entities(text, enabledTypes: types, entities: [], mediaDuration: duration)
                let second = cache.entities(text, enabledTypes: types, entities: [], mediaDuration: duration)
                XCTAssertEqual(first, direct, text)
                XCTAssertEqual(second, direct, text)
            }
        }
    }

    func test_keyIncludesEveryInput() {
        let cache = LocallyGeneratedEntitiesCache(capacity: 16)
        let text = "Back at 10:30, call +1 415 555 0132"
        let withoutTimecodes = cache.entities(text, enabledTypes: .all, entities: [], mediaDuration: nil)
        let withTimecodes = cache.entities(text, enabledTypes: EnabledEntityTypes.all.union(.timecode), entities: [], mediaDuration: 3600.0)
        XCTAssertEqual(withTimecodes, addLocallyGeneratedEntities(text, enabledTypes: EnabledEntityTypes.all.union(.timecode), entities: [], mediaDuration: 3600.0))
        XCTAssertEqual(withoutTimecodes, addLocallyGeneratedEntities(text, enabledTypes: .all, entities: [], mediaDuration: nil))
        let shortDuration = cache.entities(text, enabledTypes: EnabledEntityTypes.all.union(.timecode), entities: [], mediaDuration: 60.0)
        XCTAssertEqual(shortDuration, addLocallyGeneratedEntities(text, enabledTypes: EnabledEntityTypes.all.union(.timecode), entities: [], mediaDuration: 60.0))
        let bold = [MessageTextEntity(range: 0 ..< 4, type: .Bold)]
        XCTAssertEqual(cache.entities(text, enabledTypes: .all, entities: bold, mediaDuration: nil), addLocallyGeneratedEntities(text, enabledTypes: .all, entities: bold, mediaDuration: nil))
    }

    func test_capacityIsBounded() {
        let cache = LocallyGeneratedEntitiesCache(capacity: 4)
        for i in 0 ..< 50 {
            let _ = cache.entities("call \(i) 555 01\(i)", enabledTypes: .all, entities: [], mediaDuration: nil)
        }
        XCTAssertLessThanOrEqual(cache.count, 4)
    }

    func test_cost_detectorVersusCacheHit() {
        func bestMs(_ body: () -> Void) -> Double {
            var best = Double.greatestFiniteMagnitude
            for _ in 0 ..< 5 {
                let start = CACurrentMediaTime()
                body()
                best = min(best, (CACurrentMediaTime() - start) * 1000.0)
            }
            return best
        }
        let cache = LocallyGeneratedEntitiesCache(capacity: 64)
        for text in self.texts {
            let _ = cache.entities(text, enabledTypes: .all, entities: [], mediaDuration: nil)
        }
        let detector = bestMs {
            for text in self.texts {
                let _ = addLocallyGeneratedEntities(text, enabledTypes: .all, entities: [], mediaDuration: nil)
            }
        }
        let hit = bestMs {
            for text in self.texts {
                let _ = cache.entities(text, enabledTypes: .all, entities: [], mediaDuration: nil)
            }
        }
        print("LocallyGeneratedEntitiesCacheTests: 4 messages, detector \(String(format: "%.3f", detector)) ms, cache hit \(String(format: "%.3f", hit)) ms")
        XCTAssertLessThan(hit, detector)
    }
}
