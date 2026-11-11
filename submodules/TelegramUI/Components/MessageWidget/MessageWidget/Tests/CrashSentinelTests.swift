import XCTest
import UIKit
@testable import MessageWidget

/// Nanogram: the crash sentinel (`MessageWidgetCrashSentinel`) and the local switches (`MessageWidgetLocalSettings`).
class CrashSentinelTests: MessageWidgetTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        self.directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sentinel-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: self.directory)
        super.tearDown()
    }

    private var fileURL: URL {
        return self.directory.appendingPathComponent("sentinel.json")
    }

    /// A sentinel started over a copy of the file, as the next launch would: it blocks what the file lists as running, and
    /// leaves the file alone.
    private func peek() -> MessageWidgetCrashSentinel {
        let copy = self.directory.appendingPathComponent("copy-\(UUID().uuidString).json")
        try? FileManager.default.copyItem(at: self.fileURL, to: copy)
        return MessageWidgetCrashSentinel(url: copy)
    }

    func testTheHashIsStableAndTellsSourcesApart() {
        XCTAssertEqual(MessageWidgetCrashSentinel.hash(of: ""), "cbf29ce484222325")
        XCTAssertEqual(MessageWidgetCrashSentinel.hash(of: "a"), "af63dc4c8601ec8c")
        XCTAssertNotEqual(MessageWidgetCrashSentinel.hash(of: "<p>a</p>"), MessageWidgetCrashSentinel.hash(of: "<p>b</p>"))
    }

    func testASourceStillRunningAtTheNextLaunchIsBlocked() {
        let first = MessageWidgetCrashSentinel(url: self.fileURL)
        first.begin(source: "<p>crashes</p>")
        first.begin(source: "<p>fine</p>")
        first.end(source: "<p>fine</p>")
        XCTAssertFalse(first.isBlocked(source: "<p>crashes</p>"), "a source is blocked from the next launch, not the running one")

        let second = MessageWidgetCrashSentinel(url: self.fileURL)
        XCTAssertTrue(second.isBlocked(source: "<p>crashes</p>"))
        XCTAssertFalse(second.isBlocked(source: "<p>fine</p>"))

        // The block outlives a launch in which nothing ran.
        let third = MessageWidgetCrashSentinel(url: self.fileURL)
        XCTAssertTrue(third.isBlocked(source: "<p>crashes</p>"))
    }

    func testASourceShownByTwoBubblesIsRunningUntilBothEnd() {
        let sentinel = MessageWidgetCrashSentinel(url: self.fileURL)
        sentinel.begin(source: "x")
        sentinel.begin(source: "x")
        sentinel.end(source: "x")
        XCTAssertTrue(self.peek().isBlocked(source: "x"))
        sentinel.end(source: "x")
        XCTAssertFalse(self.peek().isBlocked(source: "x"))
    }

    func testABlockExpiresAndTheOldestAreDroppedPastTheCap() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let first = MessageWidgetCrashSentinel(url: self.fileURL, now: { now })
        first.begin(source: "old")
        let second = MessageWidgetCrashSentinel(url: self.fileURL, now: { now })
        XCTAssertTrue(second.isBlocked(source: "old"))
        now = now.addingTimeInterval(MessageWidgetCrashSentinel.blockLifetime + 1.0)
        XCTAssertFalse(second.isBlocked(source: "old"))

        // One crashed launch per source: each launch blocks the one before.
        for index in 0 ..< (MessageWidgetCrashSentinel.maximumBlocked + 10) {
            now = now.addingTimeInterval(1.0)
            let launch = MessageWidgetCrashSentinel(url: self.fileURL, now: { now })
            launch.begin(source: "s\(index)")
        }
        let reader = MessageWidgetCrashSentinel(url: self.fileURL, now: { now })
        XCTAssertEqual(reader.blockedHashes.count, MessageWidgetCrashSentinel.maximumBlocked)
        XCTAssertTrue(reader.isBlocked(source: "s\(MessageWidgetCrashSentinel.maximumBlocked + 9)"))
        XCTAssertFalse(reader.isBlocked(source: "s0"))
    }

    func testTheBackgroundLeavesNothingRunningInTheFile() {
        let sentinel = MessageWidgetCrashSentinel(url: self.fileURL, observesApplication: true)
        sentinel.begin(source: "x")
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        XCTAssertFalse(self.peek().isBlocked(source: "x"), "ended from the app switcher, not a crash")
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        XCTAssertTrue(self.peek().isBlocked(source: "x"), "running again in the foreground")
        sentinel.end(source: "x")
    }

    func testClearBlockedForgetsEverything() {
        let first = MessageWidgetCrashSentinel(url: self.fileURL)
        first.begin(source: "x")
        let second = MessageWidgetCrashSentinel(url: self.fileURL)
        XCTAssertTrue(second.isBlocked(source: "x"))
        second.clearBlocked()
        XCTAssertFalse(second.isBlocked(source: "x"))
        XCTAssertFalse(self.peek().isBlocked(source: "x"))
    }

    /// A blocked source's widget is made starting stopped (the static "Widget stopped" badge, no script), an other one runs.
    func testTheRegistryStartsABlockedSourceStopped() {
        let first = MessageWidgetCrashSentinel(url: self.fileURL)
        first.begin(source: "<!doctype html><p>blocked</p>")
        let sentinel = MessageWidgetCrashSentinel(url: self.fileURL)
        var started: [String: Bool] = [:]
        let pool = self.pool!, turn = self.turn!
        let registry = MessageWidgetRegistry(factory: { source, theme, label, max, locale, storage, context, state, startsStopped in
            started[source] = startsStopped
            return MessageWidgetInstance(source: source, theme: theme, stoppedLabel: label, maxMessageLength: max, locale: locale, storage: storage, context: context, state: state, startsStopped: startsStopped, pool: pool, waitPolicy: .unbounded, turn: turn, scale: 1.0)
        }, crashSentinel: sentinel)
        registry.beginPass(ownerId: 1, theme: .light)
        _ = registry.size(path: [], source: "<!doctype html><p>blocked</p>", width: 300.0)
        _ = registry.size(path: [1], source: "<!doctype html><p>fine</p>", width: 300.0)
        registry.endPass()
        XCTAssertEqual(started["<!doctype html><p>blocked</p>"], true)
        XCTAssertEqual(started["<!doctype html><p>fine</p>"], false)
        // The running one is noted until the registry lets it go.
        XCTAssertTrue(self.peek().isBlocked(source: "<!doctype html><p>fine</p>"))
        registry.destroyAll()
        XCTAssertFalse(self.peek().isBlocked(source: "<!doctype html><p>fine</p>"))
    }

    func testTheLocalSwitchesForWidgetsAndTheWalletAreOffByDefault() {
        let suite = "MessageWidgetLocalSettingsTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            XCTFail("no suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suite)
        }
        XCTAssertFalse(MessageWidgetLocalSettings.widgetsEnabled(defaults: defaults))
        XCTAssertFalse(MessageWidgetLocalSettings.walletEnabled(defaults: defaults))
        let sentinel = MessageWidgetCrashSentinel(url: nil)
        MessageWidgetLocalSettings.setWidgetsEnabled(false, defaults: defaults, sentinel: sentinel)
        XCTAssertFalse(MessageWidgetLocalSettings.widgetsEnabled(defaults: defaults))
        MessageWidgetLocalSettings.setWidgetsEnabled(true, defaults: defaults, sentinel: sentinel)
        XCTAssertTrue(MessageWidgetLocalSettings.widgetsEnabled(defaults: defaults))
        MessageWidgetLocalSettings.setWalletEnabled(true, defaults: defaults)
        XCTAssertTrue(MessageWidgetLocalSettings.walletEnabled(defaults: defaults))
    }
}
