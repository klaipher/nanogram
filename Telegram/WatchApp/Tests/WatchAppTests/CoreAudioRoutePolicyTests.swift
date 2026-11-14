import AVFoundation
import MediaPlayer
import XCTest
@testable import tgwatch_Watch_App

/// WATCH-AUDIO-1 / IOS-WATCH-AUDIO-1: long-form route policy, async activation, background mode, Now Playing.
@MainActor
final class CoreAudioRoutePolicyTests: XCTestCase {

    // MARK: feature flag

    func testFlagsShipOff() {
        for feature in WatchFeature.allCases where !WatchFeature.shippedOn.contains(feature) {
            XCTAssertFalse(feature.defaultValue, feature.rawValue)
        }
    }

    func testFlagReadsTheDefaultsKeyAndLaunchArgumentStyleStrings() throws {
        let suite = "nanogram.watch.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let flags = WatchFeatureFlags(store: defaults)
        XCTAssertFalse(flags.isEnabled(.longFormAudio))
        defaults.set("YES", forKey: "nanogram.watch.longFormAudio")
        XCTAssertTrue(flags.isEnabled(.longFormAudio), "a launch argument arrives as a string")
        defaults.set(false, forKey: "nanogram.watch.longFormAudio")
        XCTAssertFalse(flags.isEnabled(.longFormAudio))
    }

    // MARK: configuration

    func testLongFormConfigurationUsesTheLongFormPolicyAndAsyncActivation() {
        let c = AudioSessionConfiguration.forMusic(longForm: true)
        XCTAssertEqual(c.category, .playback)
        XCTAssertEqual(c.policy, .longFormAudio)
        XCTAssertTrue(c.activatesAsynchronously)
    }

    func testLegacyConfigurationIsTheOldSession() {
        let c = AudioSessionConfiguration.forMusic(longForm: false)
        XCTAssertEqual(c, AudioSessionConfiguration(category: .playback, mode: .default, policy: .default, activatesAsynchronously: false))
    }

    // MARK: gate

    func testGateHoldsPlayUntilActivationCompletes() {
        let gate = DeferredPlayGate()
        XCTAssertFalse(gate.requestPlay(), "not active yet: wait")
        XCTAssertTrue(gate.markReady(), "activation done: the waiting play starts")
    }

    func testGateDoesNotStartAfterAPauseDuringActivation() {
        let gate = DeferredPlayGate()
        _ = gate.requestPlay()
        gate.requestPause()
        XCTAssertFalse(gate.markReady())
        XCTAssertTrue(gate.requestPlay(), "ready now: plays at once")
    }

    func testGateResetForgetsReadiness() {
        let gate = DeferredPlayGate()
        _ = gate.markReady()
        gate.reset()
        XCTAssertFalse(gate.requestPlay())
    }

    // MARK: backend + session

    private func url() -> URL { URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString).mp3") }

    func testLongFormBackendConfiguresThenActivatesAsynchronously() async throws {
        let session = FakeAudioSession()
        let backend = AVPlayerBackend(session: session, longForm: true)
        try backend.load(url: url())
        XCTAssertEqual(session.events, ["configure:longForm"])
        let activated = await coreWait { session.events.contains("activate") }
        XCTAssertTrue(activated)
        XCTAssertFalse(session.events.contains("activateNow"))
        backend.stop()
        XCTAssertEqual(session.events.last, "deactivate")
    }

    func testLegacyBackendActivatesSynchronously() throws {
        let session = FakeAudioSession()
        let backend = AVPlayerBackend(session: session, longForm: false)
        try backend.load(url: url())
        XCTAssertEqual(session.events, ["configure:legacy", "activateNow"])
    }

    func testActivationFailureIsReported() async throws {
        let session = FakeAudioSession()
        session.activationError = NSError(domain: "test", code: 1)
        let backend = AVPlayerBackend(session: session, longForm: true)
        var failure: String?
        backend.onFailed = { failure = $0 }
        try backend.load(url: url())
        let reported = await coreWait { failure != nil }
        XCTAssertTrue(reported)
    }

    func testStopDuringActivationDoesNotReportFailure() async throws {
        let session = FakeAudioSession()
        session.activationDelayNanoseconds = 200_000_000
        session.activationError = NSError(domain: "test", code: 1)
        let backend = AVPlayerBackend(session: session, longForm: true)
        var failure: String?
        backend.onFailed = { failure = $0 }
        try backend.load(url: url())
        backend.stop()
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertNil(failure)
    }

    // MARK: Info.plist

    /// The app is built from project.yml; playback with the wrist down needs the audio background mode.
    func testAudioBackgroundModeIsDeclared() {
        let modes = Bundle.main.object(forInfoDictionaryKey: "WKBackgroundModes") as? [String]
        XCTAssertEqual(modes, ["audio"])
    }

    // MARK: Now Playing

    private func track() -> AudioVisual {
        AudioVisual(audioFileId: 7, duration: 180, title: "Song", performer: "Band", albumArt: nil, caption: "", localPath: "/tmp/x.mp3")
    }

    func testNowPlayingDictionaryCarriesTitleArtistAndRate() {
        let dict = nowPlayingDictionary(for: NowPlayingInfo(title: "Song", artist: "Band", duration: 180, elapsed: 12, rate: 1))
        XCTAssertEqual(dict[MPMediaItemPropertyTitle] as? String, "Song")
        XCTAssertEqual(dict[MPMediaItemPropertyArtist] as? String, "Band")
        XCTAssertEqual(dict[MPMediaItemPropertyPlaybackDuration] as? Double, 180)
        XCTAssertEqual(dict[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 12)
        XCTAssertEqual(dict[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1)
    }

    func testNowPlayingDictionaryOmitsAnEmptyArtist() {
        let dict = nowPlayingDictionary(for: NowPlayingInfo(title: "Song", artist: "", duration: 1, elapsed: 0, rate: 0))
        XCTAssertNil(dict[MPMediaItemPropertyArtist])
    }

    func testControllerPublishesOnPlayPauseAndClearsOnStop() {
        let publisher = FakeNowPlaying()
        let controller = AudioPlaybackController(backend: CoreFakeAudioBackend(), nowPlaying: publisher)
        controller.toggle(audio: track())
        XCTAssertEqual(publisher.published.last??.rate, 1)
        XCTAssertEqual(publisher.published.last??.title, "Song")
        controller.toggle(audio: track())
        XCTAssertEqual(publisher.published.last??.rate, 0)
        controller.toggle(audio: track())
        XCTAssertEqual(publisher.published.last??.rate, 1)
        controller.tearDown()
        XCTAssertNil(publisher.published.last!)
    }

    func testRemoteCommandsDriveThePlayer() {
        let publisher = FakeNowPlaying()
        let backend = CoreFakeAudioBackend()
        let controller = AudioPlaybackController(backend: backend, nowPlaying: publisher)
        controller.toggle(audio: track())
        publisher.onCommand?(.pause)
        XCTAssertEqual(controller.state, .paused(audioFileId: 7))
        publisher.onCommand?(.play)
        XCTAssertEqual(controller.state, .playing(audioFileId: 7))
        publisher.onCommand?(.togglePlayPause)
        XCTAssertEqual(controller.state, .paused(audioFileId: 7))
        publisher.onCommand?(.skipForward(seconds: 15))
        XCTAssertEqual(backend.skips, [15])
        XCTAssertEqual(controller.currentElapsed, 15)
        publisher.onCommand?(.skipBackward(seconds: 15))
        XCTAssertEqual(backend.skips, [15, -15])
        XCTAssertEqual(controller.currentElapsed, 0)
    }

    func testSkipForwardStopsAtTheEndOfTheTrack() {
        let controller = AudioPlaybackController(backend: CoreFakeAudioBackend(), nowPlaying: FakeNowPlaying())
        controller.toggle(audio: track())
        for _ in 0..<20 { controller.handleRemote(.skipForward(seconds: 15)) }
        XCTAssertEqual(controller.currentElapsed, 180)
    }

    func testRemoteCommandWithNothingPlayingIsIgnored() {
        let controller = AudioPlaybackController(backend: CoreFakeAudioBackend(), nowPlaying: FakeNowPlaying())
        controller.handleRemote(.play)
        XCTAssertEqual(controller.state, .idle)
    }

    func testNoPublisherMeansNoSystemTraffic() {
        let controller = AudioPlaybackController(backend: CoreFakeAudioBackend())
        controller.toggle(audio: track())
        XCTAssertEqual(controller.state, .playing(audioFileId: 7))
    }
}

@MainActor
private final class FakeAudioSession: AudioSessionActivating {
    private(set) var events: [String] = []
    var activationError: Error?
    var activationDelayNanoseconds: UInt64 = 0

    func configure(_ configuration: AudioSessionConfiguration) throws {
        events.append("configure:" + (configuration.policy == .longFormAudio ? "longForm" : "legacy"))
    }
    func activateNow() throws { events.append("activateNow") }
    func activate() async throws {
        if activationDelayNanoseconds > 0 { try? await Task.sleep(nanoseconds: activationDelayNanoseconds) }
        if let activationError { throw activationError }
        events.append("activate")
    }
    func deactivate() { events.append("deactivate") }
}

@MainActor
private final class FakeNowPlaying: NowPlayingPublishing {
    var onCommand: ((RemoteTransportCommand) -> Void)?
    private(set) var published: [NowPlayingInfo?] = []
    func publish(_ info: NowPlayingInfo?) { published.append(info) }
}
