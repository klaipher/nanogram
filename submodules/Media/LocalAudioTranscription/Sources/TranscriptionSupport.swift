import Foundation
import SwiftSignalKit

let speechAnalyzerDefaultsKey = "NanogramSpeechAnalyzer"

/// SpeechAnalyzer (iOS 26) is an experiment: off unless the key is set (launch argument `-NanogramSpeechAnalyzer YES`).
func isSpeechAnalyzerEnabled(defaults: UserDefaults = .standard) -> Bool {
    return defaults.bool(forKey: speechAnalyzerDefaultsKey)
}

/// An empty transcription has no segments; dividing by their count gave NaN, which breaks the confidence sort.
func averageTranscriptionConfidence(_ confidences: [Float]) -> Float {
    if confidences.isEmpty {
        return 0.0
    }
    return confidences.reduce(0.0, +) / Float(confidences.count)
}

func joinedTranscriptionText(_ fragments: [String]) -> String? {
    let text = fragments.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : text
}

enum TranscriptionEngine: Equatable {
    case analyzer
    case legacy
}

func transcriptionEngine(flagEnabled: Bool, osSupportsAnalyzer: Bool) -> TranscriptionEngine {
    return flagEnabled && osSupportsAnalyzer ? .analyzer : .legacy
}

/// The analyzer yields nil without a model or locale support; the on-device recognizer then takes over.
func transcriptionWithFallback<T>(primary: Signal<T?, NoError>, fallback: @escaping () -> Signal<T?, NoError>) -> Signal<T?, NoError> {
    return primary
    |> mapToSignal { result -> Signal<T?, NoError> in
        if let result {
            return .single(result)
        }
        return fallback()
    }
}
