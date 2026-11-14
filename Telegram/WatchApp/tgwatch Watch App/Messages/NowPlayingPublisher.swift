import Foundation
import MediaPlayer

/// What the Now Playing app and the Smart Stack show for the track that is playing.
struct NowPlayingInfo: Equatable {
    var title: String
    var artist: String
    var duration: Double
    var elapsed: Double
    /// 1 while playing, 0 while paused.
    var rate: Double
}

enum RemoteTransportCommand: Equatable {
    case play
    case pause
    case togglePlayPause
    case skipForward(seconds: Double)
    case skipBackward(seconds: Double)
}

/// Publishes the playing track and receives the system's transport commands. Tests substitute a fake.
@MainActor
protocol NowPlayingPublishing: AnyObject {
    /// Nil clears the Now Playing entry and unregisters the commands.
    func publish(_ info: NowPlayingInfo?)
    var onCommand: ((RemoteTransportCommand) -> Void)? { get set }
}

/// Dictionary the system reads. Kept separate from the center so it is testable.
func nowPlayingDictionary(for info: NowPlayingInfo) -> [String: Any] {
    var dict: [String: Any] = [
        MPMediaItemPropertyTitle: info.title,
        MPMediaItemPropertyPlaybackDuration: info.duration,
        MPNowPlayingInfoPropertyElapsedPlaybackTime: info.elapsed,
        MPNowPlayingInfoPropertyPlaybackRate: info.rate,
        MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
    ]
    if !info.artist.isEmpty { dict[MPMediaItemPropertyArtist] = info.artist }
    return dict
}

/// Production publisher over `MPNowPlayingInfoCenter` and `MPRemoteCommandCenter`. The commands are
/// registered when a track starts and removed when it stops, so an idle app owns none of them.
@MainActor
final class SystemNowPlayingPublisher: NowPlayingPublishing {
    var onCommand: ((RemoteTransportCommand) -> Void)?
    private var registered: [(command: MPRemoteCommand, token: Any)] = []
    private static let skipInterval = 15.0

    func publish(_ info: NowPlayingInfo?) {
        let center = MPNowPlayingInfoCenter.default()
        guard let info else {
            center.nowPlayingInfo = nil
            unregister()
            return
        }
        if registered.isEmpty { register() }
        center.nowPlayingInfo = nowPlayingDictionary(for: info)
    }

    private func register() {
        let center = MPRemoteCommandCenter.shared()
        add(center.playCommand, .play)
        add(center.pauseCommand, .pause)
        add(center.togglePlayPauseCommand, .togglePlayPause)
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: Self.skipInterval)]
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: Self.skipInterval)]
        add(center.skipForwardCommand, .skipForward(seconds: Self.skipInterval))
        add(center.skipBackwardCommand, .skipBackward(seconds: Self.skipInterval))
    }

    /// The system calls the handler on an arbitrary queue, so it is built outside the main actor (a closure
    /// written inside this `@MainActor` class would be main-actor isolated, which Swift 6 checks on entry).
    private func add(_ command: MPRemoteCommand, _ mapped: RemoteTransportCommand) {
        command.isEnabled = true
        let token = command.addTarget(handler: Self.makeHandler(mapped, publisher: self))
        registered.append((command, token))
    }

    nonisolated private static func makeHandler(
        _ mapped: RemoteTransportCommand,
        publisher: SystemNowPlayingPublisher
    ) -> (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        return { [weak publisher] _ in
            Task { @MainActor in publisher?.onCommand?(mapped) }
            return .success
        }
    }

    private func unregister() {
        for entry in registered {
            entry.command.removeTarget(entry.token)
            entry.command.isEnabled = false
        }
        registered.removeAll()
    }
}
