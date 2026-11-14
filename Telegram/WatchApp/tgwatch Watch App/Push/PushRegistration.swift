import Foundation
@preconcurrency import TDShim

/// APNs registration helpers for WATCH-INT-1. Everything that talks to the system or TDLib sits behind
/// `WatchFeature.pushRegistration`.
enum PushRegistration {
    /// Lowercase hex of an APNs device token, the form TDLib's `deviceTokenApplePush` takes.
    static func hexString(_ token: Data) -> String {
        token.map { String(format: "%02x", $0) }.joined()
    }

    /// Development builds register with the APNs sandbox, release builds with production.
    static var isSandbox: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }
}

/// `registerDevice` for TDLib. TDShim is generated from a trimmed TDLib schema without this function and its
/// `DeviceToken` type, and its `run` helper is private, so the request is built as TDLib's JSON directly.
struct RegisterDeviceQuery: TdQuery {
    let tokenHex: String
    let isSandbox: Bool

    func make(with extra: String?) throws -> Data {
        var object: [String: Any] = [
            "@type": "registerDevice",
            "device_token": [
                "@type": "deviceTokenApplePush",
                "device_token": tokenHex,
                "is_app_sandbox": isSandbox,
            ] as [String: Any],
            "other_user_ids": [Int64](),
        ]
        if let extra { object["@extra"] = extra }
        return try JSONSerialization.data(withJSONObject: object)
    }
}

/// Handle returned by `PushTokenStore.observe`; dropping it stops the callbacks.
@MainActor
final class PushTokenObservation {
    fileprivate let id = UUID()
    private weak var store: PushTokenStore?

    fileprivate init(store: PushTokenStore) {
        self.store = store
    }

    deinit {
        let id = id
        Task { @MainActor [weak store] in store?.remove(id) }
    }
}

/// The watch's APNs token, as the app delegate receives it. A client that becomes ready after the token arrived
/// still gets it.
@MainActor
final class PushTokenStore {
    static let shared = PushTokenStore()

    private(set) var token: Data?
    private var observers: [UUID: (Data) -> Void] = [:]

    init() {}

    func set(_ newToken: Data) {
        guard newToken != token else { return }
        token = newToken
        for callback in observers.values { callback(newToken) }
    }

    /// Calls `callback` now when a token exists, and on every later change.
    func observe(_ callback: @escaping (Data) -> Void) -> PushTokenObservation {
        let observation = PushTokenObservation(store: self)
        observers[observation.id] = callback
        if let token { callback(token) }
        return observation
    }

    fileprivate func remove(_ id: UUID) {
        observers.removeValue(forKey: id)
    }
}
