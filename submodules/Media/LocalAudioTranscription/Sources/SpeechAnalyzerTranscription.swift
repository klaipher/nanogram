import Foundation
import AVFoundation
import Speech

@available(iOS 26.0, *)
private final class SpeechAssetInstalls: @unchecked Sendable {
    static let shared = SpeechAssetInstalls()
    
    private let lock = NSLock()
    private var installing = Set<String>()
    
    func begin(_ identifier: String) -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.installing.insert(identifier).inserted
    }
    
    func end(_ identifier: String) {
        self.lock.lock()
        self.installing.remove(identifier)
        self.lock.unlock()
    }
}

/// On-device transcription of an audio file with SpeechAnalyzer. Returns nil when the locale or its model is not
/// available (a missing model is downloaded in the background for the next message), so the caller falls back to
/// SFSpeechRecognizer. Audio never leaves the device.
@available(iOS 26.0, *)
func transcribeWithSpeechAnalyzer(path: String, localeIdentifier: String) async -> String? {
    guard SpeechTranscriber.isAvailable, let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: localeIdentifier)) else {
        return nil
    }
    let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
    let status = await AssetInventory.status(forModules: [transcriber])
    guard status == .installed else {
        if status == .supported, SpeechAssetInstalls.shared.begin(locale.identifier) {
            let identifier = locale.identifier
            Task.detached(priority: .utility) {
                try? await AssetInventory.assetInstallationRequest(supporting: [transcriber])?.downloadAndInstall()
                SpeechAssetInstalls.shared.end(identifier)
            }
        }
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
