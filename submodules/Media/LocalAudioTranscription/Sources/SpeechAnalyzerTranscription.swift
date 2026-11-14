import Foundation
import AVFoundation
import Speech

private final class SpeechAssetInstalls: @unchecked Sendable {
    static let shared = SpeechAssetInstalls()
    
    private let lock = NSLock()
    private var running: [String: Task<Bool, Never>] = [:]
    
    func run(_ identifier: String, _ work: @escaping @Sendable () async -> Bool) -> Task<Bool, Never> {
        self.lock.lock()
        defer { self.lock.unlock() }
        if let task = self.running[identifier] {
            return task
        }
        let task = Task { () -> Bool in
            let result = await work()
            self.end(identifier)
            return result
        }
        self.running[identifier] = task
        return task
    }
    
    private func end(_ identifier: String) {
        self.lock.lock()
        self.running[identifier] = nil
        self.lock.unlock()
    }
}

private func speechModelStatus(_ status: AssetInventory.Status) -> SpeechModelStatus {
    switch status {
    case .installed:
        return .installed
    case .downloading:
        return .downloading
    case .supported:
        return .supported
    default:
        return .unsupported
    }
}

/// Makes sure the locale's model is on the device. One download per locale runs at a time; a caller that finds one running
/// awaits that same download instead of starting another or giving up.
private func ensureSpeechModel(_ transcriber: SpeechTranscriber, locale: Locale) async -> Bool {
    switch speechModelAction(for: speechModelStatus(await AssetInventory.status(forModules: [transcriber]))) {
    case .none:
        return true
    case .unavailable:
        return false
    case .install:
        return await SpeechAssetInstalls.shared.run(locale.identifier) {
            let installing = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
            do {
                try await AssetInventory.assetInstallationRequest(supporting: [installing])?.downloadAndInstall()
            } catch {
                return false
            }
            return await AssetInventory.status(forModules: [installing]) == .installed
        }.value
    }
}

/// Downloads the model of the current locale ahead of the first transcription (voice messages are on screen), so the
/// first tap does not wait for it. Nothing happens when the locale is unsupported or the model is installed.
func prepareSpeechAnalyzerModel(localeIdentifier: String) {
    Task.detached(priority: .utility) {
        guard SpeechTranscriber.isAvailable, let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: localeIdentifier)) else {
            return
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        _ = await ensureSpeechModel(transcriber, locale: locale)
    }
}

/// On-device transcription of an audio file with SpeechAnalyzer. A missing model is downloaded first (a tap during a running
/// download awaits it). Returns nil when the locale or the model is not available, so the caller falls back to SFSpeechRecognizer.
/// Audio never leaves the device.
func transcribeWithSpeechAnalyzer(path: String, localeIdentifier: String) async -> String? {
    guard SpeechTranscriber.isAvailable, let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: localeIdentifier)) else {
        return nil
    }
    let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
    guard await ensureSpeechModel(transcriber, locale: locale) else {
        return nil
    }
    guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else {
        return nil
    }
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    let results = Task { () -> [String] in
        var fragments: [String] = []
        do {
            for try await result in transcriber.results where result.isFinal {
                fragments.append(String(result.text.characters))
            }
        } catch {
        }
        return fragments
    }
    do {
        _ = try await analyzer.analyzeSequence(from: file)
        try await analyzer.finalizeAndFinishThroughEndOfInput()
    } catch {
        await analyzer.cancelAndFinishNow()
        results.cancel()
        return nil
    }
    return joinedTranscriptionText(await results.value)
}
