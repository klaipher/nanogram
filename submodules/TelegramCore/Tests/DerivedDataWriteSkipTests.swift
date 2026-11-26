import XCTest
import Postbox
@testable import TelegramCore

/// `storeLocallyDerivedData` and `updateLocallyDerivedData` skip the message rewrite when the derived data would not
/// change. A playing gallery video stores its position every few seconds, often the same value (0.0 in its first and
/// last 5 s, nothing for a short video); before the skip each of those rewrote the whole message and updated every
/// view showing it (tester critlogs: one transaction every 0.5 s for as long as a video played).
final class DerivedDataWriteSkipTests: XCTestCase {
    private struct Position: Codable {
        var timestamp: Double
    }

    private func entry(_ value: Double) -> CodableEntry {
        guard let entry = CodableEntry(Position(timestamp: value)) else {
            XCTFail("CodableEntry did not encode")
            return CodableEntry(data: Data())
        }
        return entry
    }

    private func derivedData(_ attributes: [MessageAttribute]?) -> [String: CodableEntry]? {
        guard let attributes else {
            return nil
        }
        let found = attributes.compactMap { $0 as? DerivedDataMessageAttribute }
        XCTAssertLessThanOrEqual(found.count, 1)
        return found.first?.data ?? [:]
    }

    func testSameValueIsSkipped() {
        let attributes: [MessageAttribute] = [ViewCountMessageAttribute(count: 3), DerivedDataMessageAttribute(data: ["mps": self.entry(0.0)])]
        let result = attributesReplacingDerivedData(attributes, update: { data in
            var data = data
            data["mps"] = self.entry(0.0)
            return data
        })
        XCTAssertNil(result)
    }

    func testRemovingAnAbsentKeyIsSkipped() {
        let attributes: [MessageAttribute] = [ViewCountMessageAttribute(count: 3)]
        let result = attributesReplacingDerivedData(attributes, update: { data in
            var data = data
            data.removeValue(forKey: "mps")
            return data
        })
        XCTAssertNil(result)
    }

    func testStoringEmptyDataOnAMessageWithoutTheAttributeIsSkipped() {
        let attributes: [MessageAttribute] = [ViewCountMessageAttribute(count: 3)]
        XCTAssertNil(attributesReplacingDerivedData(attributes, update: { _ in [:] }))
    }

    func testChangedValueIsWrittenAndOtherKeysKept() {
        let code = self.entry(7.0)
        let attributes: [MessageAttribute] = [DerivedDataMessageAttribute(data: ["mps": self.entry(12.0), "code": code]), ViewCountMessageAttribute(count: 3)]
        let result = attributesReplacingDerivedData(attributes, update: { data in
            var data = data
            data["mps"] = self.entry(17.5)
            return data
        })
        XCTAssertEqual(result?.count, 2)
        XCTAssertTrue(result?.contains(where: { $0 is ViewCountMessageAttribute }) ?? false)
        XCTAssertEqual(self.derivedData(result), ["mps": self.entry(17.5), "code": code])
    }

    func testRemovingTheLastKeyDropsTheAttribute() {
        let attributes: [MessageAttribute] = [DerivedDataMessageAttribute(data: ["mps": self.entry(12.0)]), ViewCountMessageAttribute(count: 3)]
        let result = attributesReplacingDerivedData(attributes, update: { data in
            var data = data
            data.removeValue(forKey: "mps")
            return data
        })
        XCTAssertEqual(result?.count, 1)
        XCTAssertFalse(result?.contains(where: { $0 is DerivedDataMessageAttribute }) ?? true)
    }

    func testFirstValueOnAMessageWithoutTheAttributeIsWritten() {
        let attributes: [MessageAttribute] = [ViewCountMessageAttribute(count: 3)]
        let result = attributesReplacingDerivedData(attributes, update: { _ in ["mps": self.entry(30.0)] })
        XCTAssertEqual(self.derivedData(result), ["mps": self.entry(30.0)])
    }

    func testUpdateSeesTheCurrentData() {
        let attributes: [MessageAttribute] = [DerivedDataMessageAttribute(data: ["code": self.entry(1.0)])]
        var seen: [String: CodableEntry] = [:]
        let _ = attributesReplacingDerivedData(attributes, update: { data in
            seen = data
            return data
        })
        XCTAssertEqual(seen, ["code": self.entry(1.0)])
    }
}
