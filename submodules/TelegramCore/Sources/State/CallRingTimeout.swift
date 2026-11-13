import Foundation
import SwiftSignalKit

typealias CallRingTimerFactory = (_ delay: Double, _ queue: Queue, _ fire: @escaping () -> Void) -> Disposable

/// How long an incoming call may ring locally. The server ends a call after `call_ring_timeout_ms`
/// and tells a connected client; a client that lost the connection while the call rang never hears
/// it, so it ends the ring itself, a little after the server would have.
enum CallRingTimeout {
    static let defaultServerTimeoutMs: Int32 = 90_000
    static let grace: Double = 10.0
    static let appConfigurationKey = "call_ring_timeout_ms"

    static func serverTimeoutMs(appConfiguration: JSON?) -> Int32? {
        guard let appConfiguration, case let .dictionary(values) = appConfiguration, case let .number(value)? = values[appConfigurationKey] else {
            return nil
        }
        guard value.isFinite, value >= 1_000, value <= 600_000 else {
            return nil
        }
        return Int32(exactly: value.rounded(.towardZero))
    }

    /// Seconds from the local receipt of the call.
    static func delay(serverTimeoutMs: Int32?) -> Double {
        return Double(serverTimeoutMs ?? defaultServerTimeoutMs) / 1000.0 + grace
    }

    static let systemTimer: CallRingTimerFactory = { delay, queue, fire in
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
