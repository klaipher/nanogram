import XCTest
@testable import LocalAudioTranscription

final class TranscriptionSupportTests: XCTestCase {
    func testEmptyTranscriptionHasZeroConfidenceNotNaN() {
        XCTAssertEqual(averageTranscriptionConfidence([]), 0.0)
        XCTAssertFalse(averageTranscriptionConfidence([]).isNaN)
    }

    func testConfidenceIsTheAverageOfTheSegments() {
        XCTAssertEqual(averageTranscriptionConfidence([0.5, 1.0, 0.75]), 0.75, accuracy: 0.0001)
    }

    func testSpeechAnalyzerIsOffByDefault() {
        let suiteName = "LocalAudioTranscriptionTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("no defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        XCTAssertFalse(isSpeechAnalyzerEnabled(defaults: defaults))
        defaults.set(true, forKey: speechAnalyzerDefaultsKey)
        XCTAssertTrue(isSpeechAnalyzerEnabled(defaults: defaults))
    }

    func testJoinedTextIsTrimmedAndEmptyIsNil() {
        XCTAssertEqual(joinedTranscriptionText(["Hello ", "world "]), "Hello world")
        XCTAssertNil(joinedTranscriptionText(["  ", "\n"]))
        XCTAssertNil(joinedTranscriptionText([]))
    }
}
