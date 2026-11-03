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

    func firstFrameLine(now: Double) -> String {
        let milliseconds = Int((max(0.0, now - self.requestTime) * 1000.0).rounded())
        let cause = self.fileIsLocal ? "file was on the device: the wait was rendering" : "file was not on the device: the wait includes its download"
        return "reaction \(self.reaction): \(self.kind.rawValue) first frame after \(milliseconds) ms (\(cause))"
    }
}
