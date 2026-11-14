import Foundation
import OSLog
import UserNotifications
import WatchKit

/// System background refresh for the watch app (WATCH-INT-1, and what keeps the widget summary fresh).
/// watchOS wakes an app that scheduled a refresh for a short run, roughly four times an hour at most. No portal
/// capability or entitlement is needed. Flag `backgroundRefresh`.
enum BackgroundRefreshPlan {
    /// Preferred spacing between refreshes; the system decides the real time within its budget.
    static let interval: TimeInterval = 30 * 60
    /// How long TDLib gets to connect and receive updates before the summary is written.
    static let syncWindow: Duration = .seconds(10)

    static func nextDate(after now: Date) -> Date {
        now.addingTimeInterval(interval)
    }
}

@MainActor
protocol BackgroundRefreshScheduling {
    func schedule(preferredDate: Date, completion: @escaping @Sendable (Bool) -> Void)
}

@MainActor
struct SystemBackgroundRefreshScheduler: BackgroundRefreshScheduling {
    func schedule(preferredDate: Date, completion: @escaping @Sendable (Bool) -> Void) {
        WKApplication.shared().scheduleBackgroundRefresh(withPreferredDate: preferredDate, userInfo: nil) { error in
            completion(error == nil)
        }
    }
}

@MainActor
final class BackgroundRefreshCoordinator {
    static let shared = BackgroundRefreshCoordinator()

    /// Replaceable so tests do not depend on the user defaults.
    var isEnabled: () -> Bool = { WatchFeatureFlags.isEnabled(.backgroundRefresh) }
    /// Installed by the app: gives TDLib `window` to catch up, then writes the widget summary.
    var syncAction: (@MainActor (Duration) async -> Void)?

    private let scheduler: BackgroundRefreshScheduling
    private let now: () -> Date
    private var scheduledFor: Date?
    private let logger = Logger(watchCategory: "backgroundrefresh")

    init(scheduler: BackgroundRefreshScheduling = SystemBackgroundRefreshScheduler(), now: @escaping () -> Date = { Date() }) {
        self.scheduler = scheduler
        self.now = now
    }

    /// Asks for the next refresh unless one is already pending in the future (the app goes inactive often).
    /// Returns true when a request was made.
    @discardableResult
    func scheduleNext() -> Bool {
        guard isEnabled() else { return false }
        let current = now()
        if let scheduledFor, scheduledFor > current { return false }
        let date = BackgroundRefreshPlan.nextDate(after: current)
        scheduledFor = date
        scheduler.schedule(preferredDate: date) { [weak self] ok in
            guard !ok else { return }
            Task { @MainActor in self?.scheduledFor = nil }
        }
        return true
    }

    /// One system-delivered refresh: sync, then schedule the following one.
    func runRefresh() async {
        scheduledFor = nil
        guard isEnabled() else { return }
        await syncAction?(BackgroundRefreshPlan.syncWindow)
        scheduleNext()
    }
}

/// The SwiftUI app's WatchKit delegate: background refresh tasks and the APNs token callbacks.
@MainActor
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    private let logger = Logger(watchCategory: "appdelegate")

    func applicationDidFinishLaunching() {
        guard WatchFeatureFlags.isEnabled(.pushRegistration) else { return }
        Task {
            // The prompt appears once; without permission pushes are delivered silently or not at all.
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            WKApplication.shared().registerForRemoteNotifications()
        }
    }

    func didRegisterForRemoteNotifications(withDeviceToken deviceToken: Data) {
        PushTokenStore.shared.set(deviceToken)
    }

    func didFailToRegisterForRemoteNotificationsWithError(_ error: Error) {
        logger.warning("push registration failed: \(error.localizedDescription, privacy: .public)")
    }

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            if let refresh = task as? WKApplicationRefreshBackgroundTask {
                Task {
                    await BackgroundRefreshCoordinator.shared.runRefresh()
                    WatchReportSession.shared.scheduleTransfer()
                    refresh.setTaskCompletedWithSnapshot(false)
                }
            } else if let snapshot = task as? WKSnapshotRefreshBackgroundTask {
                // Snapshot tasks must report a snapshot state, or the Dock and app switcher image goes stale.
                snapshot.setTaskCompleted(restoredDefaultState: true, estimatedSnapshotExpiration: .distantFuture, userInfo: nil)
            } else {
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }
}
