import Foundation
#if canImport(MetricKit)
import MetricKit
#endif

/// Phases of the extended launch that MetricKit reports (iOS 27 / macOS 27, `MetricManager.trackLaunchTask`). Reports
/// stay on the device (the apps store them locally); nothing is sent anywhere.
public enum LaunchPhase: String, CaseIterable, Sendable {
    /// The account (database, session) is loaded and its context exists.
    case accountLoad = "account-load"
    /// The chat list applied its first rows.
    case chatListFirstData = "chat-list-first-data"
    /// The main window shows the chat list for the first time.
    case firstFrame = "first-frame"
}

/// Tracks which launch phases are open and ends each exactly once. The platform part is injected so the bookkeeping
/// runs in tests: `start` opens a MetricKit task for an id and returns the closure that finishes it (or nil when the
/// OS has no launch-task API).
// Every mutable field is guarded by `lock`.
public final class LaunchTaskTracker: @unchecked Sendable {
    public typealias Starter = (_ id: String) -> (() -> Void)?

    private let lock = NSLock()
    private let start: Starter
    private var finishers: [LaunchPhase: () -> Void] = [:]
    private var begun: Set<LaunchPhase> = []
    private var ended: Set<LaunchPhase> = []

    public init(start: @escaping Starter) {
        self.start = start
    }

    /// Opens the phase. A phase opens once; later calls do nothing.
    public func begin(_ phase: LaunchPhase) {
        self.lock.lock()
        guard self.begun.insert(phase).inserted else {
            self.lock.unlock()
            return
        }
        self.lock.unlock()
        let finisher = self.start(phase.rawValue)
        self.lock.lock()
        if let finisher {
            self.finishers[phase] = finisher
        }
        self.lock.unlock()
    }

    /// Ends the phase. Does nothing when it was not opened or already ended.
    public func end(_ phase: LaunchPhase) {
        self.lock.lock()
        guard self.begun.contains(phase), self.ended.insert(phase).inserted else {
            self.lock.unlock()
            return
        }
        let finisher = self.finishers.removeValue(forKey: phase)
        self.lock.unlock()
        finisher?()
    }

    public func isOpen(_ phase: LaunchPhase) -> Bool {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.begun.contains(phase) && !self.ended.contains(phase)
    }
}

/// The launch of the app as the apps report it: the `launchToChatListReady` signpost and the MetricKit launch tasks.
/// `begin()` goes first in `didFinishLaunching` (the first launch task must start there), `end(_:)` is called from the
/// place that finishes each phase and may be called any number of times.
public enum LaunchTrace {
    private static let tracker = LaunchTaskTracker(start: LaunchTrace.metricKitStarter)

    private static let lock = NSLock()
    // Guarded by lock.
    nonisolated(unsafe) private static var didBegin = false

    public static func begin() {
        LaunchTrace.lock.lock()
        let first = !LaunchTrace.didBegin
        LaunchTrace.didBegin = true
        LaunchTrace.lock.unlock()
        guard first else {
            return
        }
        NanogramSignposts.beginPending(.launchToChatListReady)
        for phase in LaunchPhase.allCases {
            LaunchTrace.tracker.begin(phase)
        }
    }

    public static func end(_ phase: LaunchPhase) {
        LaunchTrace.tracker.end(phase)
        if phase == .firstFrame {
            NanogramSignposts.endPending(.launchToChatListReady)
        }
    }

    private static func metricKitStarter(id: String) -> (() -> Void)? {
        #if canImport(MetricKit)
        if #available(iOS 27.0, macOS 27.0, *) {
            return MetricKitLaunchTasks.start(id: id)
        }
        #endif
        return nil
    }
}

#if canImport(MetricKit)
@available(iOS 27.0, macOS 27.0, *)
@available(tvOS, unavailable)
@available(watchOS, unavailable)
@available(visionOS, unavailable)
enum MetricKitLaunchTasks {
    private static let manager = MetricManager()

    /// `trackLaunchTask` brackets an operation, so the open task is an operation that waits for the finish closure.
    static func start(id: String) -> (() -> Void)? {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        Task { @MainActor in
            await MetricKitLaunchTasks.manager.trackLaunchTask(id: LaunchTaskID(rawValue: id), onTrackingError: { error in
                NSLog("MetricKit: launch task \(id) is not tracked (reason \(error.reason.rawValue))")
            }) {
                for await _ in stream {
                    break
                }
            }
        }
        return {
            continuation.yield(())
            continuation.finish()
        }
    }
}
#endif
