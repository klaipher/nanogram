import AVFoundation
import Foundation

/// How the audio session is set up for music-file playback. Pure data so the choice is testable.
///
/// Long-form audio is what lets watchOS route to Bluetooth headphones (the system route picker appears when
/// no output is available) and, with the `audio` background mode, keep playing with the wrist down. The
/// category stays `.playback` either way; mode is `.default` because these are music files, whose route the
/// user chose (IOS-WATCH-AUDIO-1 suggests `.spokenAudio`, WATCH-AUDIO-1 `.default`: music files are not
/// speech, so `.default` is used; flip `longFormMusic.mode` if long podcasts turn out to be the main use).
/// Video keeps its own speaker-only `.moviePlayback` session; voice notes and recording are untouched.
struct AudioSessionConfiguration: Equatable {
    var category: AVAudioSession.Category
    var mode: AVAudioSession.Mode
    var policy: AVAudioSession.RouteSharingPolicy
    /// True: activate with `activate(options:)` (async, shows the route picker); false: the old synchronous
    /// `setActive(true)`.
    var activatesAsynchronously: Bool

    static let legacyMusic = AudioSessionConfiguration(
        category: .playback, mode: .default, policy: .default, activatesAsynchronously: false
    )
    static let longFormMusic = AudioSessionConfiguration(
        category: .playback, mode: .default, policy: .longFormAudio, activatesAsynchronously: true
    )

    static func forMusic(longForm: Bool) -> AudioSessionConfiguration {
        longForm ? longFormMusic : legacyMusic
    }
}

/// The part of `AVAudioSession` the music backend uses; tests substitute a fake.
@MainActor
protocol AudioSessionActivating {
    func configure(_ configuration: AudioSessionConfiguration) throws
    /// The old synchronous activation.
    func activateNow() throws
    /// Async activation; presents the route picker when there is no output (long-form policy).
    func activate() async throws
    func deactivate()
}

@MainActor
struct SystemAudioSession: AudioSessionActivating {
    func configure(_ configuration: AudioSessionConfiguration) throws {
        try AVAudioSession.sharedInstance().setCategory(
            configuration.category, mode: configuration.mode, policy: configuration.policy, options: []
        )
    }

    func activateNow() throws {
        try AVAudioSession.sharedInstance().setActive(true)
    }

    func activate() async throws {
        _ = try await Self.activateSharedSession()
    }

    func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    /// The session is fetched inside, so no non-Sendable reference crosses the actor boundary.
    @concurrent
    nonisolated private static func activateSharedSession() async throws -> Bool {
        try await AVAudioSession.sharedInstance().activate(options: [])
    }
}

/// Holds a `play()` that arrives while the session is still activating (the route picker can be open for
/// seconds) and releases it once activation succeeds. A pause or stop in between cancels it.
@MainActor
final class DeferredPlayGate {
    private(set) var isReady = false
    private(set) var wantsPlay = false

    /// True when playback can start right away.
    func requestPlay() -> Bool {
        wantsPlay = true
        return isReady
    }

    func requestPause() {
        wantsPlay = false
    }

    /// Activation finished. True when a play request is waiting.
    func markReady() -> Bool {
        isReady = true
        return wantsPlay
    }

    func reset() {
        isReady = false
        wantsPlay = false
    }
}
