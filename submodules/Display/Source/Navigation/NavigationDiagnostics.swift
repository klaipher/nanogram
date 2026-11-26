import Foundation

/// Diagnostic log for screen changes in a navigation container (tester report 2026-11-20: on one phone, after
/// iOS 27.2.1, a chat tapped in the chat list never appears and back does nothing; no crash or hang). Logs every
/// change of the stack, the screen a push or pop waits for, and each transition's start and end; a screen still not
/// ready, or a transition still running, `stallDelay` seconds later is logged with what the screen reports about
/// itself (`ViewController.navigationReadinessReport`). Nothing here changes behaviour.
public enum NavigationDiagnostics {
    /// Set by the app to its file log (`Logger.shared.log("Navigation", ...)`); nil logs nothing. The app also sends the
    /// lines `belongsInShortLog` picks to its always-on short log.
    public static var log: ((String) -> Void)?

    public static let stallDelay: Double = 3.0

    /// Whether a line is one of the rare ones (a screen or transition still pending `stallDelay` later, or a recovery
    /// from one) that must also reach the always-on short log, which a report carries even with Log to File off. Every
    /// stack change, transition and ready line stays in the file log only: they come with every screen change.
    public static func belongsInShortLog(_ line: String) -> Bool {
        return line.hasPrefix("stall:") || line.hasPrefix("recovery:")
    }

    static func emit(_ text: @autoclosure () -> String) {
        guard let log = NavigationDiagnostics.log else {
            return
        }
        log(text())
    }

    /// A short, stable name for a screen in the log: its type and identity.
    public static func describe(_ controller: AnyObject?) -> String {
        guard let controller else {
            return "nil"
        }
        return "\(type(of: controller))@\(UInt(bitPattern: ObjectIdentifier(controller).hashValue) & 0xffffff)"
    }

    /// One line for a stack: its screens bottom to top.
    public static func describeStack(_ controllers: [AnyObject]) -> String {
        return "[" + controllers.map { describe($0) }.joined(separator: ", ") + "]"
    }

    /// The stored properties of `value` that differ from `defaults`, as `name=value` (for logging which Debug switches
    /// a phone has changed: they live outside the account database, so a database reset keeps them).
    public static func differingFields<T>(_ value: T, from defaults: T) -> [String] {
        var defaultValues: [String: String] = [:]
        for child in Mirror(reflecting: defaults).children {
            if let label = child.label {
                defaultValues[label] = String(describing: child.value)
            }
        }
        var result: [String] = []
        for child in Mirror(reflecting: value).children {
            guard let label = child.label else {
                continue
            }
            let text = String(describing: child.value)
            if defaultValues[label] != text {
                result.append("\(label)=\(text)")
            }
        }
        return result
    }

    /// The readiness inputs a screen waits for, as recorded so far: each input's last value, or "never" when it has
    /// not produced one. Inputs are listed in the order given.
    public static func readinessReport(order: [String], values: [String: Bool]) -> String {
        return order.map { name -> String in
            if let value = values[name] {
                return "\(name)=\(value)"
            } else {
                return "\(name)=never"
            }
        }.joined(separator: " ")
    }
}

/// Records the last value of each named readiness input; read from any thread.
public final class NavigationReadinessRecorder {
    private let lock = NSLock()
    private var values: [String: Bool] = [:]
    public let order: [String]

    public init(order: [String]) {
        self.order = order
    }

    public func record(_ name: String, _ value: Bool) {
        self.lock.lock()
        self.values[name] = value
        self.lock.unlock()
    }

    public func reset() {
        self.lock.lock()
        self.values.removeAll()
        self.lock.unlock()
    }

    public var report: String {
        self.lock.lock()
        let values = self.values
        self.lock.unlock()
        return NavigationDiagnostics.readinessReport(order: self.order, values: values)
    }
}

/// Recovery from a stalled screen change (tester report 2026-11-20: on one phone a chat tapped in the chat list never
/// appeared and back did nothing until the app was reinstalled; the cause was not found). A push waits for its screen's
/// `ready` with no timeout and a tap push or pop waits for its animation to land, so either one never finishing
/// leaves the stack frozen. These rules bound both waits; each recovery is logged (`NavigationDiagnostics`).
public enum NavigationRecovery {
    /// How long a screen that opted in (`ViewController.showsWhenReadyStalls`) may stay not ready before it is shown
    /// as it is. A chat reports ready after its first local layout (well under a second), not after the network.
    public static let pendingReadyTimeout: Double = 5.0
    /// How long a tap push or pop may animate before it is landed at its end. Its spring settles in about 0.5 s.
    public static let transitionTimeout: Double = 3.0

    /// Whether a pending screen is shown although it never reported ready: it is still the one the push waits for,
    /// it has not become ready, and it opted in.
    public static func showsPendingScreen(isStillPending: Bool, isReady: Bool, optedIn: Bool) -> Bool {
        return isStillPending && !isReady && optedIn
    }

    /// Whether a running transition is landed at its end: it is still the container's transition and nothing is
    /// steering it (a finger may hold a swipe for as long as it likes).
    public static func landsTransition(isStillRunning: Bool, isInteractive: Bool, hasInteractivePop: Bool) -> Bool {
        return isStillRunning && !isInteractive && !hasInteractivePop
    }
}
