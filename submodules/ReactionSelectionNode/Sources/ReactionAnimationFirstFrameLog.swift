import Foundation

/// The log lines for one of a sent reaction's animations (its larger animation, which stands in for
/// the message's button, or its effect): when it was asked for, and when it drew its first frame.
///
/// Each says whether the animation's file was on the device when it was asked for. A late first
/// frame with the file there was the renderer's (frames drawn for the first time, a busy queue);
/// without it, the wait includes the download. The owner's recording of 202611031553 showed both
/// animations empty for about 2 s, and without this the two causes read the same in a log.
struct ReactionAnimationFirstFrameLog {
    enum Kind: String {
        case largerAnimation = "larger animation"
        case effect = "effect"
    }

    let kind: Kind
    let reaction: String
    let fileIsLocal: Bool
    let requestTime: Double

    var requestedLine: String {
        return "reaction \(self.reaction): \(self.kind.rawValue) requested, \(self.fileIsLocal ? "file on the device" : "file not on the device yet")"
    }

    /// `playStartTime` is when the animation was allowed to play, if that was later than the request on
    /// purpose: the effect is created at once but only made visible 0.15 s later, and nothing is drawn
    /// before that. With it, the line names that delay apart and blames rendering only for the rest.
    func firstFrameLine(now: Double, playStartTime: Double? = nil) -> String {
        let milliseconds = ReactionAnimationFirstFrameLog.milliseconds(now - self.requestTime)
        let cause: String
        if let playStartTime = playStartTime {
            let heldBack = min(milliseconds, ReactionAnimationFirstFrameLog.milliseconds(playStartTime - self.requestTime))
            let afterPlayStart = milliseconds - heldBack
            let rest = self.fileIsLocal ? "file was on the device: the other \(afterPlayStart) ms was rendering" : "file was not on the device: the wait includes its download"
            cause = "\(heldBack) ms of it held back on purpose before playing; \(rest)"
        } else {
            cause = self.fileIsLocal ? "file was on the device: the wait was rendering" : "file was not on the device: the wait includes its download"
        }
        return "reaction \(self.reaction): \(self.kind.rawValue) first frame after \(milliseconds) ms (\(cause))"
    }

    private static func milliseconds(_ interval: Double) -> Int {
        return Int((max(0.0, interval) * 1000.0).rounded())
    }
}

/// When a reaction's effect was allowed to play, set on the main queue by the block that makes it
/// visible and read on the main queue by its first-frame callback.
final class ReactionAnimationPlayStart {
    var time: Double?
}
