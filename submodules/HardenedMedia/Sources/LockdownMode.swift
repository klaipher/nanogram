import Foundation
#if os(macOS)
import Security
#endif

public struct LockdownModeSources: Sendable {
    public var officialState: (@Sendable () -> Bool)?
    public var legacyDefaultsFlag: @Sendable () -> Bool

    public init(officialState: (@Sendable () -> Bool)?, legacyDefaultsFlag: @escaping @Sendable () -> Bool) {
        self.officialState = officialState
        self.legacyDefaultsFlag = legacyDefaultsFlag
    }

    public static func make(hasStateEntitlement: Bool, officialAPI: @escaping @Sendable () -> Bool, defaults: UserDefaults) -> LockdownModeSources {
        nonisolated(unsafe) let defaults = defaults
        return LockdownModeSources(
            officialState: hasStateEntitlement ? officialAPI : nil,
            legacyDefaultsFlag: { defaults.bool(forKey: LockdownMode.legacyDefaultsKey) }
        )
    }

    public static var system: LockdownModeSources {
        return make(
            hasStateEntitlement: LockdownMode.appHoldsStateEntitlement(),
            officialAPI: { LockdownMode.callOfficialAPI() },
            defaults: .standard
        )
    }
}

public enum LockdownMode {
    public static let legacyDefaultsKey = "LDMGlobalEnabled"
    public static let stateEntitlement = "com.apple.developer.lockdown-mode.state"
    public static let entitlementInfoPlistKey = "NanogramHasLockdownStateEntitlement"

    public static func isEnabled(sources: LockdownModeSources) -> Bool {
        if let officialState = sources.officialState {
            return officialState()
        }
        return sources.legacyDefaultsFlag()
    }

    public static let current: Bool = isEnabled(sources: .system)

    static func appHoldsStateEntitlement() -> Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else {
            return false
        }
        return entitlementValueGrantsAccess(SecTaskCopyValueForEntitlement(task, stateEntitlement as CFString, nil))
        #else
        return entitlementValueGrantsAccess(Bundle.main.object(forInfoDictionaryKey: entitlementInfoPlistKey))
        #endif
    }

    /// The official call aborts the process unless the entitlement is granted, so only a boolean `true` counts:
    /// an entitlement present with `false` (or any other value) must fall back to the defaults flag.
    static func entitlementValueGrantsAccess(_ value: Any?) -> Bool {
        guard let value = value as? Bool else {
            return false
        }
        return value
    }

    static func callOfficialAPI() -> Bool {
        typealias Entry = @convention(c) () -> Bool
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "os_lockdown_mode_enabled") else {
            return false
        }
        return unsafeBitCast(symbol, to: Entry.self)()
    }
}
