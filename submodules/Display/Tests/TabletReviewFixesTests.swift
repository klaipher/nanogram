import XCTest
import UIKit
import SwiftSignalKit
@testable import Display

/// Review of the iPad audit batch (2026-11-03): C1 Live Text threading, I1 orientation lock, I2 menu-bar property
/// lists, I3 lazy Live Text analysis, I4 thermal hysteresis, I5 the phone's Power Saving signal.
final class TabletReviewFixesTests: XCTestCase {
    // MARK: - Fakes

    /// A manual clock and timer queue: `fire(upTo:)` runs every scheduled action due by then, in order.
    private final class ManualScheduler {
        struct Entry {
            let due: Double
            let action: () -> Void
            var isCancelled: Bool
        }
        var time: Double = 0.0
        private(set) var entries: [Entry] = []
        var delays: [Double] = []

        func schedule(_ delay: Double, _ action: @escaping () -> Void) -> Disposable {
            self.delays.append(delay)
            let index = self.entries.count
            self.entries.append(Entry(due: self.time + delay, action: action, isCancelled: false))
            return ActionDisposable { [weak self] in
                self?.entries[index].isCancelled = true
            }
        }

        var pendingCount: Int {
            return self.entries.filter { !$0.isCancelled }.count
        }

        func advance(to time: Double) {
            self.time = time
            var index = 0
            while index < self.entries.count {
                if !self.entries[index].isCancelled && self.entries[index].due <= time {
                    self.entries[index].isCancelled = true
                    let action = self.entries[index].action
                    action()
                }
                index += 1
            }
        }
    }

    private func liveTextConditions(deviceType: DeviceType = .tablet, isSupported: Bool = true, isContentProtected: Bool = false, isAnalysisDisabled: Bool = false, isPowerSaving: Bool = false) -> GalleryLiveTextConditions {
        return GalleryLiveTextConditions(deviceType: deviceType, isSupported: isSupported, isContentProtected: isContentProtected, isAnalysisDisabled: isAnalysisDisabled, isPowerSaving: isPowerSaving)
    }

    private func spinMainRunLoop(until condition: () -> Bool, timeout: Double = 5.0) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    // MARK: - C1 Live Text is attached on the main thread, once

    /// The gallery reports a ready image from a background queue, medium and full quality at nearly the same time.
    /// The interaction must be added on the main thread (VisionKit's `ImageAnalysisInteraction` is main-actor; the
    /// old `MainActor.assumeIsolated` trapped there), and only once.
    func test_liveText_imageReadyFromBackground_attachesOnMainOnce() {
        let scheduler = ManualScheduler()
        let liveText = GalleryLiveTextScheduler(schedule: scheduler.schedule)
        var attachCount = 0
        var attachedOffMain = false
        var conditionsReadOffMain = false
        liveText.attach = {
            attachCount += 1
            if !Thread.isMainThread {
                attachedOffMain = true
            }
        }
        liveText.analyze = { _ in }

        let group = DispatchGroup()
        for _ in 0 ..< 2 {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                liveText.imageReady(makeImage: { return nil }, conditions: {
                    if !Thread.isMainThread {
                        conditionsReadOffMain = true
                    }
                    return self.liveTextConditions()
                })
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5.0), .success)
        self.spinMainRunLoop(until: { attachCount >= 1 })
        // Let a second, wrong attach land if it is coming.
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(attachCount, 1)
        XCTAssertFalse(attachedOffMain, "attach ran off the main thread")
        XCTAssertFalse(conditionsReadOffMain, "the view and conditions were read off the main thread")
    }

    // MARK: - I3 Live Text analyses lazily

    /// A neighbour the pager preloads is never analysed; the current page is, once it has stayed current for the
    /// dwell delay, with the latest image.
    func test_liveText_analysesOnlyTheCurrentPageAfterDwell() {
        let scheduler = ManualScheduler()
        let liveText = GalleryLiveTextScheduler(schedule: scheduler.schedule)
        var analyses: [String] = []
        liveText.attach = {}
        liveText.analyze = { makeImage in
            analyses.append(makeImage()?.accessibilityIdentifier ?? "nil")
        }
        let medium = UIImage()
        medium.accessibilityIdentifier = "medium"
        let full = UIImage()
        full.accessibilityIdentifier = "full"

        liveText.imageReady(makeImage: { medium }, conditions: { self.liveTextConditions() })
        scheduler.advance(to: 10.0)
        XCTAssertEqual(analyses, [], "a page that is not current must not be analysed")

        liveText.centralityUpdated(isCentral: true)
        liveText.imageReady(makeImage: { full }, conditions: { self.liveTextConditions() })
        scheduler.advance(to: 10.0 + GalleryLiveTextScheduler.dwellDelay - 0.1)
        XCTAssertEqual(analyses, [])
        scheduler.advance(to: 10.0 + GalleryLiveTextScheduler.dwellDelay)
        XCTAssertEqual(analyses, ["full"])

        // Once per photo.
        liveText.centralityUpdated(isCentral: false)
        liveText.centralityUpdated(isCentral: true)
        scheduler.advance(to: 20.0)
        XCTAssertEqual(analyses, ["full"])
    }

    /// Swiping past a photo within the dwell delay does not analyse it.
    func test_liveText_swipedPastIsNotAnalysed() {
        let scheduler = ManualScheduler()
        let liveText = GalleryLiveTextScheduler(schedule: scheduler.schedule)
        var analysisCount = 0
        liveText.attach = {}
        liveText.analyze = { _ in analysisCount += 1 }
        liveText.imageReady(makeImage: { nil }, conditions: { self.liveTextConditions() })
        liveText.centralityUpdated(isCentral: true)
        scheduler.advance(to: 0.2)
        liveText.centralityUpdated(isCentral: false)
        scheduler.advance(to: 5.0)
        XCTAssertEqual(analysisCount, 0)
    }

    /// The Debug switch that turns off Telegram's own recognition, Power Saving, phones and protected media: no
    /// interaction, no analysis.
    func test_liveText_offWhenDisabledPowerSavingPhoneOrProtected() {
        XCTAssertTrue(galleryAnalyzesSystemLiveText(self.liveTextConditions()))
        XCTAssertFalse(galleryAnalyzesSystemLiveText(self.liveTextConditions(isAnalysisDisabled: true)))
        XCTAssertFalse(galleryAnalyzesSystemLiveText(self.liveTextConditions(isPowerSaving: true)))
        XCTAssertFalse(galleryAnalyzesSystemLiveText(self.liveTextConditions(deviceType: .phone)))
        XCTAssertFalse(galleryAnalyzesSystemLiveText(self.liveTextConditions(isSupported: false)))
        XCTAssertFalse(galleryAnalyzesSystemLiveText(self.liveTextConditions(isContentProtected: true)))

        for conditions in [self.liveTextConditions(isAnalysisDisabled: true), self.liveTextConditions(isPowerSaving: true), self.liveTextConditions(deviceType: .phone)] {
            let scheduler = ManualScheduler()
            let liveText = GalleryLiveTextScheduler(schedule: scheduler.schedule)
            var calls = 0
            liveText.attach = { calls += 1 }
            liveText.analyze = { _ in calls += 1 }
            liveText.imageReady(makeImage: { nil }, conditions: { conditions })
            liveText.centralityUpdated(isCentral: true)
            scheduler.advance(to: 5.0)
            XCTAssertEqual(calls, 0, "\(conditions)")
        }
    }

    /// Another photo in the same node: the old interaction goes, the new photo is attached and analysed again.
    func test_liveText_resetForAnotherPhoto() {
        let scheduler = ManualScheduler()
        let liveText = GalleryLiveTextScheduler(schedule: scheduler.schedule)
        var events: [String] = []
        liveText.attach = { events.append("attach") }
        liveText.analyze = { _ in events.append("analyze") }
        liveText.detach = { events.append("detach") }

        liveText.reset()
        XCTAssertEqual(events, [], "nothing attached yet: nothing to detach")
        liveText.centralityUpdated(isCentral: true)
        liveText.imageReady(makeImage: { nil }, conditions: { self.liveTextConditions() })
        scheduler.advance(to: 1.0)
        liveText.reset()
        liveText.imageReady(makeImage: { nil }, conditions: { self.liveTextConditions() })
        scheduler.advance(to: 2.0)
        XCTAssertEqual(events, ["attach", "analyze", "detach", "attach", "analyze"])
    }

    // MARK: - Live Text draws nothing until the user asks

    /// Opening a photo must not underline dates, times or links: data detectors highlight what they find at once.
    /// By default only text selection (a long press) is on, which draws nothing until the user presses.
    func test_liveText_interactionTypes_defaultDrawsNothing() {
        let types = galleryLiveTextInteractionTypes(userRequestedRecognition: false)
        XCTAssertEqual(types, [.textSelection])
        XCTAssertFalse(types.contains(.dataDetectors))
    }

    func test_liveText_interactionTypes_dataDetectorsOnlyWhenRequested() {
        let types = galleryLiveTextInteractionTypes(userRequestedRecognition: true)
        XCTAssertTrue(types.contains(.textSelection))
        XCTAssertTrue(types.contains(.dataDetectors))
    }

    // MARK: - I1 Orientation lock: single-axis masks only

    func test_orientationLock_onlySingleAxisMasksLock() {
        // No lock: everything, or the compact default without upside-down, or two axes.
        XCTAssertFalse(windowPrefersInterfaceOrientationLocked(deviceType: .tablet, supportedOrientations: .all))
        XCTAssertFalse(windowPrefersInterfaceOrientationLocked(deviceType: .tablet, supportedOrientations: .allButUpsideDown))
        XCTAssertFalse(windowPrefersInterfaceOrientationLocked(deviceType: .tablet, supportedOrientations: [.portrait, .landscapeLeft]))
        XCTAssertFalse(windowPrefersInterfaceOrientationLocked(deviceType: .tablet, supportedOrientations: []))
        // Lock: one axis (what `lockOrientation` produces: the current orientation alone).
        XCTAssertTrue(windowPrefersInterfaceOrientationLocked(deviceType: .tablet, supportedOrientations: .portrait))
        XCTAssertTrue(windowPrefersInterfaceOrientationLocked(deviceType: .tablet, supportedOrientations: .portraitUpsideDown))
        XCTAssertTrue(windowPrefersInterfaceOrientationLocked(deviceType: .tablet, supportedOrientations: [.portrait, .portraitUpsideDown]))
        XCTAssertTrue(windowPrefersInterfaceOrientationLocked(deviceType: .tablet, supportedOrientations: .landscapeLeft))
        XCTAssertTrue(windowPrefersInterfaceOrientationLocked(deviceType: .tablet, supportedOrientations: .landscape))
        // Never on a phone.
        XCTAssertFalse(windowPrefersInterfaceOrientationLocked(deviceType: .phone, supportedOrientations: .portrait))
    }

    // MARK: - I2 Menu-bar commands are unique by action and property list

    /// UIKit identifies main-menu commands by action and property list; every item of every Nanogram menu shares
    /// one action, so each must carry its own property list (its key), and a key command must still match its
    /// shortcut.
    @available(iOS 26.0, *)
    func test_menuCommands_uniqueActionAndPropertyList() {
        var shortcuts: [(title: String, input: String, modifiers: UIKeyModifierFlags)] = [
            ("New Message", "N", [.command]),
            ("Lock", "L", [.command]),
            ("Close", "W", [.command]),
            ("Search in Chat", "F", [.command]),
            ("Chat Info", "I", [.command, .control]),
            ("Previous Chat", UIKeyCommand.inputUpArrow, [.alternate]),
            ("Next Chat", UIKeyCommand.inputDownArrow, [.alternate]),
            ("Strikethrough", "X", [.command, .shift]),
            ("Link", "K", [.command])
        ]
        for digit in 1 ... 9 {
            shortcuts.append(("Folder \(digit)", "\(digit)", [.command]))
        }
        var seen = Set<String>()
        var count = 0
        for section in MainMenuSection.allCases {
            let items = mainMenuItems(section: section, shortcuts: shortcuts)
            let commands = KeyShortcutsController.mainMenuCommands(for: items)
            XCTAssertEqual(commands.count, items.count)
            for (item, command) in zip(items, commands) {
                count += 1
                let propertyList = command.propertyList as? String
                XCTAssertEqual(propertyList, KeyShortcutsController.mainMenuPropertyList(input: item.input, modifiers: item.modifiers), item.title)
                let key = "\(NSStringFromSelector(command.action))|\(propertyList ?? "nil")"
                XCTAssertFalse(seen.contains(key), "duplicate menu command \(key) (\(item.title))")
                seen.insert(key)
                if let keyCommand = command as? UIKeyCommand {
                    XCTAssertEqual(keyCommand.input, item.input)
                    XCTAssertEqual(keyCommand.modifierFlags, item.modifiers)
                }
            }
        }
        XCTAssertEqual(count, 18)
    }

    // MARK: - I4 Thermal Power Saving does not flap

    private func conditions(thermal: ProcessInfo.ThermalState = .nominal, lowPower: Bool = false) -> SystemEnergyConditions {
        return SystemEnergyConditions(thermalState: thermal, isLowPowerModeEnabled: lowPower, prefersReducedResourceUsage: false)
    }

    /// Serious turns it on at once; it turns off only after the state has stayed at fair or below for
    /// `thermalReleaseDelay`, measured from the last time it was serious.
    func test_monitor_thermalHysteresis() {
        let center = NotificationCenter()
        let scheduler = ManualScheduler()
        var current = self.conditions()
        let monitor = SystemEnergyConditionsMonitor(notificationCenter: center, read: { current }, now: { scheduler.time }, schedule: scheduler.schedule)
        monitor.observesSystemConditions = true

        var values: [Bool] = []
        let disposable = monitor.requestsEnergySavingUpdates().start(next: { values.append($0) })
        func post(at time: Double, _ conditions: SystemEnergyConditions) {
            scheduler.advance(to: time)
            current = conditions
            center.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        }

        post(at: 0.0, self.conditions(thermal: .serious))
        XCTAssertEqual(values.last, true)
        // Flapping between fair and serious keeps it on.
        post(at: 10.0, self.conditions(thermal: .fair))
        XCTAssertEqual(values.last, true)
        post(at: 30.0, self.conditions(thermal: .serious))
        post(at: 40.0, self.conditions(thermal: .fair))
        XCTAssertTrue(monitor.requestsEnergySaving)
        scheduler.advance(to: 40.0 + SystemEnergyConditionsMonitor.thermalReleaseDelay - 1.0)
        XCTAssertTrue(monitor.requestsEnergySaving)
        XCTAssertEqual(values.last, true)
        // Cool for the whole delay: off, without another notification.
        scheduler.advance(to: 40.0 + SystemEnergyConditionsMonitor.thermalReleaseDelay)
        XCTAssertEqual(values.last, false)
        XCTAssertFalse(monitor.requestsEnergySaving)

        var transitions: [Bool] = []
        for value in values where transitions.last != value {
            transitions.append(value)
        }
        XCTAssertEqual(transitions, [false, true, false])
        disposable.dispose()
        XCTAssertEqual(scheduler.pendingCount, 0, "a disposed subscription leaves no timer")
    }

    /// Low Power Mode is the user's switch: it clears at once.
    func test_monitor_lowPowerClearsImmediately() {
        let scheduler = ManualScheduler()
        var current = self.conditions(lowPower: true)
        let monitor = SystemEnergyConditionsMonitor(notificationCenter: NotificationCenter(), read: { current }, now: { scheduler.time }, schedule: scheduler.schedule)
        monitor.observesSystemConditions = true
        XCTAssertTrue(monitor.requestsEnergySaving)
        current = self.conditions()
        scheduler.advance(to: 1.0)
        XCTAssertFalse(monitor.requestsEnergySaving)
    }

    // MARK: - I5 Without the system signals, upstream's battery signal

    func test_monitor_observesSystemOnlyOnceTurnedOn() {
        let monitor = SystemEnergyConditionsMonitor(notificationCenter: NotificationCenter(), read: { .nominal })
        XCTAssertFalse(monitor.observesSystemConditions)
        monitor.observesSystemConditions = true
        XCTAssertTrue(monitor.observesSystemConditions)
    }

    /// The review's premise for I5 was that `combineLatest(battery, system |> deliverOnMainQueue) |> runOn(main)`
    /// delivers its first value a run-loop turn late. Subscribed on the main thread it does not: SwiftSignalKit's
    /// `Queue.async` and `runOn` run inline on the current queue. Pinned so the shape can be compared.
    func test_combinedEnergySignalShape_firstValueIsSynchronousOnMain() {
        XCTAssertTrue(Thread.isMainThread)
        let battery = Signal<Void, NoError> { subscriber in
            subscriber.putNext(Void())
            return EmptyDisposable
        }
        let system: Signal<Bool, NoError> = .single(false)
        var values: [Bool] = []
        let disposable = (combineLatest(battery, system |> deliverOnMainQueue)
        |> map { _, value -> Bool in value }
        |> runOn(Queue.mainQueue())
        |> distinctUntilChanged).start(next: { values.append($0) })
        XCTAssertEqual(values, [false])
        disposable.dispose()
    }
}
