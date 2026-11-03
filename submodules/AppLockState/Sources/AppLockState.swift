import Foundation
import MonotonicTime

public struct MonotonicTimestamp: Codable, Equatable {
    public var bootTimestamp: Int32
    public var uptime: Int32

    public init(bootTimestamp: Int32, uptime: Int32) {
        self.bootTimestamp = bootTimestamp
        self.uptime = uptime
    }
}

public struct UnlockAttempts: Codable, Equatable {
    public var count: Int32
    public var timestamp: MonotonicTimestamp

    public init(count: Int32, timestamp: MonotonicTimestamp) {
        self.count = count
        self.timestamp = timestamp
    }
}

public struct LockState: Codable, Equatable {
    public var isManuallyLocked: Bool
    public var autolockTimeout: Int32?
    public var unlockAttempts: UnlockAttempts?
    public var applicationActivityTimestamp: MonotonicTimestamp?

    public init(isManuallyLocked: Bool = false, autolockTimeout: Int32? = nil, unlockAttemts: UnlockAttempts? = nil, applicationActivityTimestamp: MonotonicTimestamp? = nil) {
        self.isManuallyLocked = isManuallyLocked
        self.autolockTimeout = autolockTimeout
        self.unlockAttempts = unlockAttemts
        self.applicationActivityTimestamp = applicationActivityTimestamp
    }
}

public func appLockStatePath(rootPath: String) -> String {
    return rootPath + "/lockState.json"
}

/// Whether the passcode lock applies at `now`, and when it will if the auto-lock has not run out yet.
public enum AppLockSchedule: Equatable {
    case unlocked
    case locked
    /// Unlocked now; locked after this many seconds unless the app is used again.
    case locksIn(Int32)
}

public func appLockSchedule(state: LockState?, now: MonotonicTimestamp) -> AppLockSchedule {
    guard let state else {
        return .unlocked
    }
    if state.isManuallyLocked {
        return .locked
    }
    guard let autolockTimeout = state.autolockTimeout else {
        return .unlocked
    }
    guard let applicationActivityTimestamp = state.applicationActivityTimestamp, applicationActivityTimestamp.bootTimestamp == now.bootTimestamp else {
        return .locked
    }
    let deadline = Int64(applicationActivityTimestamp.uptime) + Int64(autolockTimeout)
    if Int64(now.uptime) >= deadline {
        return .locked
    }
    return .locksIn(Int32(clamping: deadline - Int64(now.uptime)))
}

public func currentMonotonicTimestamp() -> MonotonicTimestamp {
    var bootTimestamp: Int32 = 0
    let uptime = getDeviceUptimeSeconds(&bootTimestamp)
    return MonotonicTimestamp(bootTimestamp: bootTimestamp, uptime: uptime)
}

/// The app's lock state as it last wrote it (`appLockStatePath`), nil without one.
public func readAppLockState(rootPath: String) -> LockState? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: appLockStatePath(rootPath: rootPath))) else {
        return nil
    }
    return try? JSONDecoder().decode(LockState.self, from: data)
}

public func isAppLocked(state: LockState) -> Bool {
    return appLockSchedule(state: state, now: currentMonotonicTimestamp()) == .locked
}
