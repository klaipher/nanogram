import SwiftUI
import WatchKit
@preconcurrency import TDShim

@main
struct TgwatchApp: App {
    /// Background refresh tasks and APNs token callbacks (WATCH-INT-1); background refresh is on by default, push stays off.
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var appDelegate
    @State private var manager: AccountManager
    @Environment(\.scenePhase) private var scenePhase
    /// True when running inside an XCTest process. Computed once and stored so
    /// both `init()` and `body` can reference the same value without repeating
    /// the `NSClassFromString` lookup.
    private let isUnderXCTest: Bool = NSClassFromString("XCTestCase") != nil

    @MainActor
    init() {
        TgwatchApp.wipeMessageDatabaseIfRequested()
        // Under XCTest the app's `@main` `init()` still runs inside the test
        // process. Instantiating a `TDLibClientManager` here would conflict
        // with the one tests create via `SharedTestTDLibManager` (TDLib's
        // `td_receive` is single-thread-global — see CLAUDE.md gotcha). Hand
        // the test process a no-bootstrap manager; tests never drive the
        // SwiftUI scene, so its `factory` is never invoked.
        let factory: any TDClientFactory
        if isUnderXCTest {
            factory = NoopTDClientFactory()
        } else {
            factory = LiveTDClientFactory(manager: TDLibClientManager())
        }
        let mgr = AccountManager(
            registry: .defaultProduction(),
            factory: factory
        )
        if !isUnderXCTest {
            mgr.bootstrap()
            // A system refresh launches the app, which bootstraps TDLib above; give it a moment to connect and
            // receive updates, then write the widget summary from the cache.
            BackgroundRefreshCoordinator.shared.syncAction = { [weak mgr] window in
                try? await Task.sleep(for: window)
                mgr?.activeClient?.publishWidgetSnapshotNow()
            }
        }
        _manager = State(initialValue: mgr)
    }

    var body: some Scene {
        WindowGroup {
            if let client = manager.activeClient {
                ContentView()
                    .environment(client)
                    .environment(manager)
                    .id(manager.activeAccountId)
            } else if !isUnderXCTest {
                // Under XCTest the scene is not test-driven; suppress
                // AccountBootstrapView so its .task doesn't call
                // ensureAccountExists() → factory.make() via NoopTDClientFactory.
                AccountBootstrapView()
                    .environment(manager)
            }
        }
        // Wrist down (inactive) or background: the open chat stops marking messages read.
        .onChange(of: scenePhase, initial: true) { _, phase in
            manager.setSceneActive(phase == .active)
            if phase != .active { BackgroundRefreshCoordinator.shared.scheduleNext() }
        }
    }

    /// DEBUG-only: deletes TDLib's sqlite message-database files (keeping
    /// `td.binlog`, which holds auth keys) for every existing account dir
    /// when `TGWATCH_WIPE_MESSAGE_DB=1`. Each launch then re-fetches chat
    /// history from the server cold.
    private static func wipeMessageDatabaseIfRequested() {
#if DEBUG
        guard ProcessInfo.processInfo.environment["TGWATCH_WIPE_MESSAGE_DB"] == "1" else { return }
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("tdlib", isDirectory: true)
        guard let entries = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else { return }
        for entry in entries {
            guard UUID(uuidString: entry.lastPathComponent) != nil else { continue }
            for name in ["db.sqlite", "db.sqlite-shm", "db.sqlite-wal"] {
                try? fm.removeItem(at: entry.appendingPathComponent(name))
            }
        }
#endif
    }
}
