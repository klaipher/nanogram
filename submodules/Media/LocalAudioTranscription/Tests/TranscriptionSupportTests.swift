import XCTest
import SwiftSignalKit
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

    func testTheAnalyzerNeedsTheFlagAndTheOS() {
        XCTAssertEqual(transcriptionEngine(flagEnabled: true, osSupportsAnalyzer: true), .analyzer)
        XCTAssertEqual(transcriptionEngine(flagEnabled: false, osSupportsAnalyzer: true), .legacy)
        XCTAssertEqual(transcriptionEngine(flagEnabled: true, osSupportsAnalyzer: false), .legacy)
        XCTAssertEqual(transcriptionEngine(flagEnabled: false, osSupportsAnalyzer: false), .legacy)
    }

    private func firstValue(_ signal: Signal<String?, NoError>) -> String?? {
        var value: String??
        let disposable = signal.start(next: { value = .some($0) })
        disposable.dispose()
        return value
    }

    func testAnalyzerResultIsUsedWithoutTheFallback() {
        var fallbackCalled = false
        let result = firstValue(transcriptionWithFallback(primary: .single("analyzer"), fallback: {
            fallbackCalled = true
            return .single("legacy")
        }))
        XCTAssertEqual(result, .some("analyzer"))
        XCTAssertFalse(fallbackCalled)
    }

    func testMissingAnalyzerResultFallsBackToTheLegacyRecognizer() {
        let result = firstValue(transcriptionWithFallback(primary: .single(nil), fallback: { .single("legacy") }))
        XCTAssertEqual(result, .some("legacy"))
    }
}
