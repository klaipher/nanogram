import Foundation
import XCTest
@testable import TelegramCore

final class SuggestedLocalizationReconcileTests: XCTestCase {
    func testMissingServerCodeKeepsTheStoredEntry() {
        let current = SuggestedLocalizationEntry(languageCode: "uk", isSeen: true)
        let result = reconcileSuggestedLocalization(current: current, serverCode: nil, seenCodes: ["uk"])
        XCTAssertEqual(result?.languageCode, "uk")
        XCTAssertEqual(result?.isSeen, true)
    }

    func testMissingServerCodeWithoutEntryStaysEmpty() {
        XCTAssertNil(reconcileSuggestedLocalization(current: nil, serverCode: nil, seenCodes: []))
    }

    func testSameCodeKeepsTheSeenFlag() {
        let current = SuggestedLocalizationEntry(languageCode: "uk", isSeen: true)
        XCTAssertEqual(reconcileSuggestedLocalization(current: current, serverCode: "uk", seenCodes: [])?.isSeen, true)
        let unseen = SuggestedLocalizationEntry(languageCode: "uk", isSeen: false)
        XCTAssertEqual(reconcileSuggestedLocalization(current: unseen, serverCode: "uk", seenCodes: ["uk"])?.isSeen, false)
    }

    func testChangedCodeStartsUnseen() {
        let current = SuggestedLocalizationEntry(languageCode: "uk", isSeen: true)
        let result = reconcileSuggestedLocalization(current: current, serverCode: "de", seenCodes: ["uk"])
        XCTAssertEqual(result?.languageCode, "de")
        XCTAssertEqual(result?.isSeen, false)
    }

    func testNewEntryWithoutStoredOneIsUnseen() {
        let result = reconcileSuggestedLocalization(current: nil, serverCode: "fr", seenCodes: [])
        XCTAssertEqual(result?.languageCode, "fr")
        XCTAssertEqual(result?.isSeen, false)
    }

    func testFlipBackToASeenCodeStaysSeen() {
        let current = SuggestedLocalizationEntry(languageCode: "de", isSeen: false)
        let result = reconcileSuggestedLocalization(current: current, serverCode: "uk", seenCodes: ["uk"])
        XCTAssertEqual(result?.languageCode, "uk")
        XCTAssertEqual(result?.isSeen, true)
    }

    func testSeenCodesAreDeduplicatedAndBounded() {
        var seen = SuggestedLocalizationSeenCodes(codes: [])
        for index in 0 ..< 40 {
            seen = seen.inserting("c\(index % 20)")
        }
        XCTAssertLessThanOrEqual(seen.codes.count, SuggestedLocalizationSeenCodes.maxCount)
        XCTAssertEqual(Set(seen.codes).count, seen.codes.count)
        XCTAssertEqual(seen.codes.last, "c19")
    }

    func testTransitionDescription() {
        let text = suggestedLocalizationTransitionDescription(current: SuggestedLocalizationEntry(languageCode: "uk", isSeen: true), serverCode: nil, result: nil)
        XCTAssertEqual(text, "stored uk seen=true, server none -> none")
    }
}
