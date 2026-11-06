import Foundation
import CoreGraphics

public struct ScrollActivityDebounce {
    public let timeout: Double
    public private(set) var lastActivity: Double?

    public init(timeout: Double) {
        self.timeout = timeout
    }

    public mutating func note(at time: Double) -> Bool {
        let wasIdle = lastActivity == nil
        lastActivity = time
        return wasIdle
    }

    public func remaining(at time: Double) -> Double? {
        guard let lastActivity = lastActivity else {
            return nil
        }
        let remaining = timeout - (time - lastActivity)
        return remaining > 1e-9 ? remaining : nil
    }

    public mutating func expire(at time: Double) -> Double? {
        if let remaining = remaining(at: time) {
            return remaining
        }
        lastActivity = nil
        return nil
    }

    public mutating func reset() {
        lastActivity = nil
    }
}
