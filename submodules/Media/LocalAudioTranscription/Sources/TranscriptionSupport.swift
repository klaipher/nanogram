import Foundation

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
