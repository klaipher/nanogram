import Foundation
@preconcurrency import Postbox
import SwiftSignalKit

typealias CallRingTimerFactory = (_ delay: Double, _ queue: Queue, _ fire: @escaping () -> Void) -> Disposable

/// How long an incoming call may ring locally. The server ends a call after `call_ring_timeout_ms`
/// and tells a connected client; a client that lost the connection while the call rang never hears
/// it, so it ends the ring itself, a little after the server would have.
enum CallRingTimeout {
    static let defaultServerTimeoutMs: Int32 = 90_000
    static let grace: Double = 10.0

    /// The server sends the timeout as `help.getConfig` `call_ring_timeout_ms`, not as an app config key.
    static func validatedServerTimeoutMs(_ value: Int32?) -> Int32? {
        guard let value, value >= 1_000, value <= 600_000 else {
            return nil
        }
        return value
    }

    nonisolated(unsafe) static let preferencesKey: ValueBoxKey = {
        let key = ValueBoxKey(length: 4)
        key.setInt32(0, value: 7_100)
        return key
    }()

    static func store(transaction: Transaction, serverTimeoutMs: Int32?) {
        let configuration = CallRingTimeoutConfiguration(serverTimeoutMs: validatedServerTimeoutMs(serverTimeoutMs))
        if current(transaction: transaction) != configuration {
            transaction.setPreferencesEntry(key: preferencesKey, value: PreferencesEntry(configuration))
        }
    }

    static func current(transaction: Transaction) -> CallRingTimeoutConfiguration {
        return transaction.getPreferencesEntry(key: preferencesKey)?.get(CallRingTimeoutConfiguration.self) ?? CallRingTimeoutConfiguration(serverTimeoutMs: nil)
    }

    /// Seconds from the local receipt of the call.
    static func delay(serverTimeoutMs: Int32?) -> Double {
        return Double(serverTimeoutMs ?? defaultServerTimeoutMs) / 1000.0 + grace
    }

    static func systemTimer(delay: Double, queue: Queue, fire: @escaping () -> Void) -> Disposable {
        let timer = SwiftSignalKit.Timer(timeout: delay, repeat: false, completion: {
            fire()
        }, queue: queue)
        timer.start()
        return ActionDisposable {
            timer.invalidate()
        }
    }

    /// Calls `expire` once after `delay`, and only while `isRinging` still holds; every later state
    /// (accepted, dropped, terminated) is left alone.
    static func arm(delay: Double, queue: Queue, makeTimer: CallRingTimerFactory, isRinging: @escaping () -> Bool, expire: @escaping () -> Void) -> Disposable {
        return makeTimer(delay, queue, {
            if isRinging() {
                expire()
            }
        })
    }
}

struct CallRingTimeoutConfiguration: Equatable, Codable {
    var serverTimeoutMs: Int32?
}
