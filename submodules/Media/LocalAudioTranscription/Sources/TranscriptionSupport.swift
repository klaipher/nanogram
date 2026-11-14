import Foundation
import SwiftSignalKit

let speechAnalyzerDefaultsKey = "NanogramSpeechAnalyzer"

/// SpeechAnalyzer (iOS 26) is the default engine; `-NanogramSpeechAnalyzer NO` (or the default set to false) turns it off.
func isSpeechAnalyzerEnabled(defaults: UserDefaults = .standard) -> Bool {
    if defaults.object(forKey: speechAnalyzerDefaultsKey) == nil {
        return true
    }
    return defaults.bool(forKey: speechAnalyzerDefaultsKey)
}

/// A voice message is transcribed on the device whenever the switch is on; the server (a Premium feature with a free
/// trial) only takes over when the device produced no text and the account may use it.
public func shouldRetryTranscriptionOnServer(deviceProducedText: Bool, serverAllowed: Bool) -> Bool {
    return !deviceProducedText && serverAllowed
}

/// What the locale's model needs before the analyzer can run.
enum SpeechModelAction: Equatable {
    case none
    case install
    case unavailable
}

enum SpeechModelStatus: Equatable {
    case installed
    case downloading
    case supported
    case unsupported
}

func speechModelAction(for status: SpeechModelStatus) -> SpeechModelAction {
    switch status {
    case .installed:
        return .none
    case .downloading, .supported:
        return .install
    case .unsupported:
        return .unavailable
    }
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
