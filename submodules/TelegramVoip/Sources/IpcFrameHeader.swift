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

/// Reader side: whether the frame in the shared file is one that has not been converted yet.
public struct IpcFrameChangeDetector {
    private var lastCounter: UInt32 = 0

    public init() {
    }

    public mutating func shouldDeserialize(counter: UInt32) -> Bool {
        if counter == 0 {
            // A writer that does not count: every poll may be a new frame.
            return true
        }
        if counter == self.lastCounter {
            return false
        }
        self.lastCounter = counter
        return true
    }
}
