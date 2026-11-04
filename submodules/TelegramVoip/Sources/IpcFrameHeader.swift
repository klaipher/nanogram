import Foundation

/// The first four bytes of the frame the screen-share extension shares with the app. They always held the
/// `CGImagePropertyOrientation` (1...8). The orientation stays in the low 8 bits, so a reader that knows
/// nothing of the counter still reads it from a counter-less writer; the upper 24 bits are a frame counter
/// (0 means "the writer does not count").
public enum IpcFrameHeader {
    public static func pack(orientation: UInt32, counter: UInt32) -> Int32 {
        return Int32(bitPattern: (orientation & 0xFF) | ((counter & 0xFFFFFF) << 8))
    }

    public static func unpack(_ value: Int32) -> (orientation: UInt32, counter: UInt32) {
        let raw = UInt32(bitPattern: value)
        return (raw & 0xFF, raw >> 8)
    }

    /// 1 ... 0xFFFFFF; zero is reserved for "not counted".
    public static func nextCounter(_ counter: UInt32) -> UInt32 {
        if counter >= 0xFFFFFF {
            return 1
        }
        return counter + 1
    }
}

public enum IpcFrameAction: Equatable {
    /// A frame the app has not converted yet: deserialize it and send it.
    case convert
    /// The screen has not changed: send the last converted frame again, without converting.
    case resend
    case skip
}

/// Reader side: what the poll should do with the frame in the shared file.
///
/// ReplayKit calls the extension only when the screen changes, so a still screen produces no new frames.
/// The encoder still needs input (a viewer joining, or a peer asking for a keyframe, is served only on the
/// next input frame), so the last frame is sent again every `resendInterval`. Only the conversion is
/// skipped, which was the expensive part.
public struct IpcFrameChangeDetector {
    public static let resendInterval: Double = 0.1

    private var lastCounter: UInt32 = 0
    private var lastSendTime: Double?

    public init() {
    }

    public mutating func action(counter: UInt32, now: Double) -> IpcFrameAction {
        if counter == 0 || counter != self.lastCounter {
            // counter 0: a writer that does not count, every poll may be a new frame.
            self.lastCounter = counter
            self.lastSendTime = now
            return .convert
        }
        if let lastSendTime = self.lastSendTime, now - lastSendTime >= IpcFrameChangeDetector.resendInterval {
            self.lastSendTime = now
            return .resend
        }
        return .skip
    }
}
