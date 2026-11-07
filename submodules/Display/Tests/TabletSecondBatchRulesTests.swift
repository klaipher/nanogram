import XCTest
import UIKit
import QuartzCore
import SwiftSignalKit
@testable import Display

/// The second iPad batch of the iPadOS 27 audit (2026-11-03): B-3 Power Saving signals, B-1 display-link cap and
/// pacing log, A-6 menu bar, A-14/B-7 Pencil, A-8 orientation locks. Every case pairs the iPad behaviour with the
/// phone one, which must stay what upstream does, except B-3, which applies to every device now (`EnergyRulesTests`).
final class TabletSecondBatchRulesTests: XCTestCase {
    // MARK: B-3 Power Saving follows the system

    private func conditions(thermal: ProcessInfo.ThermalState = .nominal, lowPower: Bool = false, reduced: Bool = false) -> SystemEnergyConditions {
        return SystemEnergyConditions(thermalState: thermal, isLowPowerModeEnabled: lowPower, prefersReducedResourceUsage: reduced)
    }

    func test_eachSystemSignalRequestsEnergySaving() {
        XCTAssertFalse(systemRequestsEnergySaving(self.conditions()))
        XCTAssertFalse(systemRequestsEnergySaving(self.conditions(thermal: .fair)))
        XCTAssertTrue(systemRequestsEnergySaving(self.conditions(thermal: .serious)))
        XCTAssertTrue(systemRequestsEnergySaving(self.conditions(thermal: .critical)))
        XCTAssertTrue(systemRequestsEnergySaving(self.conditions(lowPower: true)))
        XCTAssertTrue(systemRequestsEnergySaving(self.conditions(reduced: true)))
    }

    /// In automatic mode a system request turns Power Saving on with a full battery, and off again when it clears.
    func test_automatic_followsSystemRequest() {
        XCTAssertTrue(automaticEnergySavingIsOn(activationThreshold: 15, batteryLevel: 1.0, systemRequests: true))
        XCTAssertFalse(automaticEnergySavingIsOn(activationThreshold: 15, batteryLevel: 1.0, systemRequests: false))
        // Battery-less reading (monitoring off) does not block the system request.
        XCTAssertTrue(automaticEnergySavingIsOn(activationThreshold: 15, batteryLevel: -1.0, systemRequests: true))
    }

    /// "Off" (the slider at its minimum) is the user's explicit choice: nothing turns Power Saving on.
    func test_userOff_isNeverOverridden() {
        XCTAssertFalse(automaticEnergySavingIsOn(activationThreshold: 4, batteryLevel: 0.01, systemRequests: true))
        XCTAssertFalse(automaticEnergySavingIsOn(activationThreshold: 0, batteryLevel: 1.0, systemRequests: true))
    }

    func test_userAlways_staysOn() {
        XCTAssertTrue(automaticEnergySavingIsOn(activationThreshold: 96, batteryLevel: 1.0, systemRequests: false))
    }

    /// Without a system request the rule is upstream's battery rule.
    func test_withoutSystemRequest_isUpstreamBatteryRule() {
        for threshold: Int32 in [0, 4, 5, 15, 50, 95, 96, 100] {
            for level: Float in [-1.0, 0.0, 0.1, 0.15, 0.5, 1.0] {
                XCTAssertEqual(
                    automaticEnergySavingIsOn(activationThreshold: threshold, batteryLevel: level, systemRequests: false),
                    automaticEnergySavingBatteryConditionIsOn(activationThreshold: threshold, batteryLevel: level),
                    "threshold \(threshold), level \(level)"
                )
            }
        }
    }

    func test_monitor_followsNotificationsAndClears() {
        let center = NotificationCenter()
        var current = self.conditions()
        // A clock the test moves: a serious thermal state is released only after the hysteresis delay
        // (`TabletReviewFixesTests.test_monitor_thermalHysteresis`); no timer is left behind.
        var time = 0.0
        let monitor = SystemEnergyConditionsMonitor(notificationCenter: center, read: { current }, now: { time }, schedule: { _, _ in EmptyDisposable })
        monitor.observesSystemConditions = true

        var values: [Bool] = []
        let disposable = monitor.requestsEnergySavingUpdates().start(next: { values.append($0) })
        XCTAssertFalse(monitor.requestsEnergySaving)

        current = self.conditions(thermal: .serious)
        center.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        XCTAssertTrue(monitor.requestsEnergySaving)

        current = self.conditions(lowPower: true)
        center.post(name: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil)

        time += SystemEnergyConditionsMonitor.thermalReleaseDelay
        current = self.conditions()
        center.post(name: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil)
        XCTAssertFalse(monitor.requestsEnergySaving)

        XCTAssertEqual(values, [false, true, true, false])
        disposable.dispose()

        // Nothing is delivered after disposal.
        current = self.conditions(thermal: .critical)
        center.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        XCTAssertEqual(values.count, 4)
    }

    // MARK: B-1 Shared display link rate

    private let ipadMax: Float = 120.0

    /// Cap off (the default) is upstream: an iPad's shared link always runs at up to 120 Hz.
    func test_capOff_tabletAlwaysAsks120() {
        for requested: SharedDisplayLinkDriver.FramesPerSecond in [.fps(30), .fps(60), .fps(120), .max] {
            let range = sharedDisplayLinkFrameRateRange(requested: requested, displayMaxFramesPerSecond: self.ipadMax, isTablet: true, capsTabletRate: false)
            XCTAssertEqual(range, CAFrameRateRange(minimum: 30.0, maximum: 120.0, preferred: 120.0), "\(requested)")
        }
    }

    func test_capOn_tabletFollowsRequestedRate() {
        XCTAssertEqual(sharedDisplayLinkFrameRateRange(requested: .fps(30), displayMaxFramesPerSecond: self.ipadMax, isTablet: true, capsTabletRate: true), CAFrameRateRange(minimum: 15.0, maximum: 30.0, preferred: 30.0))
        XCTAssertEqual(sharedDisplayLinkFrameRateRange(requested: .fps(60), displayMaxFramesPerSecond: self.ipadMax, isTablet: true, capsTabletRate: true), CAFrameRateRange(minimum: 30.0, maximum: 60.0, preferred: 60.0))
        XCTAssertEqual(sharedDisplayLinkFrameRateRange(requested: .fps(120), displayMaxFramesPerSecond: self.ipadMax, isTablet: true, capsTabletRate: true), CAFrameRateRange(minimum: 30.0, maximum: 120.0, preferred: 120.0))
        XCTAssertEqual(sharedDisplayLinkFrameRateRange(requested: .max, displayMaxFramesPerSecond: self.ipadMax, isTablet: true, capsTabletRate: true), CAFrameRateRange(minimum: 30.0, maximum: 120.0, preferred: 120.0))
    }

    /// Phones never see the override, whatever the switch says.
    func test_phone_unaffectedBySwitch() {
        for requested: SharedDisplayLinkDriver.FramesPerSecond in [.fps(30), .fps(60), .fps(120), .max] {
            XCTAssertEqual(
                sharedDisplayLinkFrameRateRange(requested: requested, displayMaxFramesPerSecond: self.ipadMax, isTablet: false, capsTabletRate: true),
                sharedDisplayLinkFrameRateRange(requested: requested, displayMaxFramesPerSecond: self.ipadMax, isTablet: false, capsTabletRate: false)
            )
        }
        XCTAssertEqual(sharedDisplayLinkFrameRateRange(requested: .fps(60), displayMaxFramesPerSecond: self.ipadMax, isTablet: false, capsTabletRate: false), CAFrameRateRange(minimum: 30.0, maximum: 60.0, preferred: 60.0))
    }

    /// "Display link: Telegram's rate" (scroll A/B): upstream 13.2's rule on every device, whatever the iPad cap says.
    func test_upstreamRate_matchesTelegram() {
        for capsTabletRate in [false, true] {
            XCTAssertEqual(sharedDisplayLinkFrameRateRange(requested: .fps(30), displayMaxFramesPerSecond: self.ipadMax, isTablet: false, capsTabletRate: capsTabletRate, followsUpstreamRate: true), .default)
            XCTAssertEqual(sharedDisplayLinkFrameRateRange(requested: .fps(60), displayMaxFramesPerSecond: self.ipadMax, isTablet: false, capsTabletRate: capsTabletRate, followsUpstreamRate: true), .default)
            XCTAssertEqual(sharedDisplayLinkFrameRateRange(requested: .fps(120), displayMaxFramesPerSecond: self.ipadMax, isTablet: false, capsTabletRate: capsTabletRate, followsUpstreamRate: true), CAFrameRateRange(minimum: 30.0, maximum: 120.0, preferred: 120.0))
            XCTAssertEqual(sharedDisplayLinkFrameRateRange(requested: .max, displayMaxFramesPerSecond: self.ipadMax, isTablet: false, capsTabletRate: capsTabletRate, followsUpstreamRate: true), CAFrameRateRange(minimum: 30.0, maximum: 120.0, preferred: 120.0))
            for requested: SharedDisplayLinkDriver.FramesPerSecond in [.fps(30), .fps(60), .fps(120), .max] {
                XCTAssertEqual(sharedDisplayLinkFrameRateRange(requested: requested, displayMaxFramesPerSecond: self.ipadMax, isTablet: true, capsTabletRate: capsTabletRate, followsUpstreamRate: true), CAFrameRateRange(minimum: 30.0, maximum: 120.0, preferred: 120.0), "\(requested)")
                XCTAssertEqual(sharedDisplayLinkFrameRateRange(requested: requested, displayMaxFramesPerSecond: 60.0, isTablet: false, capsTabletRate: capsTabletRate, followsUpstreamRate: true), .default, "60 Hz screen, \(requested)")
            }
        }
    }

    /// Off (the default) keeps ours: a phone's link asks for 60 Hz or 30 Hz when its animations need no more.
    func test_upstreamRateOff_keepsOurPhoneRule() {
        XCTAssertEqual(sharedDisplayLinkFrameRateRange(requested: .fps(60), displayMaxFramesPerSecond: self.ipadMax, isTablet: false, capsTabletRate: false, followsUpstreamRate: false), CAFrameRateRange(minimum: 30.0, maximum: 60.0, preferred: 60.0))
        XCTAssertEqual(sharedDisplayLinkFrameRateRange(requested: .fps(30), displayMaxFramesPerSecond: self.ipadMax, isTablet: false, capsTabletRate: false, followsUpstreamRate: false), CAFrameRateRange(minimum: 15.0, maximum: 30.0, preferred: 30.0))
    }

    func test_pacingStats_countsFramesRateAndLateFrames() {
        var stats = DisplayLinkPacingStats()
        var t = 100.0
        stats.record(timestamp: t, frameDuration: 1.0 / 60.0)
        for i in 0 ..< 600 {
            // Every 100th interval is a dropped frame (two frame durations).
            t += (i % 100 == 99) ? 2.0 / 60.0 : 1.0 / 60.0
            stats.record(timestamp: t, frameDuration: 1.0 / 60.0)
        }
        XCTAssertEqual(stats.frames, 600)
        XCTAssertEqual(stats.lateFrames, 6)
        XCTAssertEqual(stats.longestInterval, 2.0 / 60.0, accuracy: 1e-9)
        XCTAssertEqual(stats.elapsed, 606.0 / 60.0, accuracy: 1e-6)

        let line = stats.summary(windowDuration: 10.0, capsTabletRate: true, preferredFramesPerSecond: 60.0)
        XCTAssertNotNil(line)
        XCTAssertTrue(line?.contains("cap=on") == true, line ?? "")
        XCTAssertTrue(line?.contains("frames=600") == true, line ?? "")
        XCTAssertTrue(line?.contains("late=6") == true, line ?? "")
        XCTAssertNil(stats.summary(windowDuration: 30.0, capsTabletRate: true, preferredFramesPerSecond: 60.0))
    }

    /// A pause is not a late frame.
    func test_pacingStats_pauseIsNotAFrame() {
        var stats = DisplayLinkPacingStats()
        stats.record(timestamp: 0.0, frameDuration: 1.0 / 120.0)
        stats.record(timestamp: 1.0 / 120.0, frameDuration: 1.0 / 120.0)
        stats.pause()
        stats.record(timestamp: 5.0, frameDuration: 1.0 / 120.0)
        XCTAssertEqual(stats.frames, 1)
        XCTAssertEqual(stats.lateFrames, 0)
    }

    // MARK: A-6 Menu bar

    func test_menuBar_tabletOnly() {
        XCTAssertTrue(mainMenuIsInstalled(deviceType: .tablet, available: true))
        XCTAssertFalse(mainMenuIsInstalled(deviceType: .tablet, available: false))
        XCTAssertFalse(mainMenuIsInstalled(deviceType: .phone, available: true))
    }

    func test_menuSections() {
        XCTAssertEqual(mainMenuSection(input: "N", modifiers: [.command]), .file)
        XCTAssertEqual(mainMenuSection(input: "L", modifiers: [.command]), .file)
        XCTAssertEqual(mainMenuSection(input: "W", modifiers: [.command]), .file)
        for digit in 1 ... 9 {
            XCTAssertEqual(mainMenuSection(input: "\(digit)", modifiers: [.command]), .view)
        }
        XCTAssertEqual(mainMenuSection(input: "F", modifiers: [.command]), .chat)
        XCTAssertEqual(mainMenuSection(input: "I", modifiers: [.command, .control]), .chat)
        XCTAssertEqual(mainMenuSection(input: UIKeyCommand.inputUpArrow, modifiers: [.alternate]), .chat)
        XCTAssertEqual(mainMenuSection(input: UIKeyCommand.inputDownArrow, modifiers: [.alternate, .shift]), .chat)
        // ⌘B/I/U stay the system Format menu's (Font); Nanogram lists the formats the system has no key for.
        XCTAssertNil(mainMenuSection(input: "B", modifiers: [.command]))
        XCTAssertNil(mainMenuSection(input: "I", modifiers: [.command]))
        XCTAssertNil(mainMenuSection(input: "U", modifiers: [.command]))
        XCTAssertEqual(mainMenuSection(input: "X", modifiers: [.command, .shift]), .format)
        XCTAssertEqual(mainMenuSection(input: "M", modifiers: [.command, .shift]), .format)
        XCTAssertEqual(mainMenuSection(input: "P", modifiers: [.command, .shift]), .format)
        XCTAssertEqual(mainMenuSection(input: "K", modifiers: [.command]), .format)
    }

    func test_keyboardOnlyShortcutsAreNotListed() {
        XCTAssertNil(mainMenuSection(input: "\r", modifiers: []))
        XCTAssertNil(mainMenuSection(input: "\t", modifiers: []))
        XCTAssertNil(mainMenuSection(input: UIKeyCommand.inputEscape, modifiers: []))
        XCTAssertNil(mainMenuSection(input: UIKeyCommand.inputUpArrow, modifiers: []))
        XCTAssertNil(mainMenuSection(input: "2", modifiers: [.shift]))
        XCTAssertNil(mainMenuSection(input: "3", modifiers: [.command, .alternate]))
        XCTAssertNil(mainMenuSection(input: "0", modifiers: [.command]))
    }

    func test_menuItems_titledUniqueAndSystemKeysTitleOnly() {
        let shortcuts: [(title: String, input: String, modifiers: UIKeyModifierFlags)] = [
            ("New Message", "N", [.command]),
            ("Lock with Passcode", "L", [.command]),
            ("", "X", [.command, .shift]),
            ("Strikethrough", "X", [.command, .shift]),
            ("Search in Chat", "F", [.command]),
            ("Close", "W", [.command]),
            ("New Message (again)", "N", [.command]),
            ("Chat Info", "I", [.command, .control])
        ]
        let file = mainMenuItems(section: .file, shortcuts: shortcuts)
        XCTAssertEqual(file.map(\.title), ["New Message (again)", "Lock with Passcode", "Close"])
        let close = file.first(where: { $0.input == "W" })
        XCTAssertEqual(close?.showsKeyEquivalent, false)
        XCTAssertEqual(close?.isRepeatable, false)
        XCTAssertEqual(file.first(where: { $0.input == "L" })?.isRepeatable, false)
        XCTAssertEqual(file.first(where: { $0.input == "N" })?.showsKeyEquivalent, true)

        let format = mainMenuItems(section: .format, shortcuts: shortcuts)
        XCTAssertEqual(format.map(\.title), ["Strikethrough"])
        XCTAssertEqual(format.first?.showsKeyEquivalent, true)
        let chat = mainMenuItems(section: .chat, shortcuts: shortcuts)
        XCTAssertEqual(chat.map(\.title), ["Search in Chat", "Chat Info"])
        // ⌘F is the system's Find: listed by title only.
        XCTAssertEqual(chat.first?.showsKeyEquivalent, false)
    }

    /// Items come in the table's order (File: New, Lock, Close; Format: strikethrough, monospace, spoiler, link),
    /// not in the screens' order.
    func test_menuItems_tableOrder() {
        let shortcuts: [(title: String, input: String, modifiers: UIKeyModifierFlags)] = [
            ("Link", "K", [.command]),
            ("Strikethrough", "X", [.command, .shift]),
            ("Monospace", "M", [.command, .shift])
        ]
        XCTAssertEqual(mainMenuItems(section: .format, shortcuts: shortcuts).map(\.title), ["Strikethrough", "Monospace", "Link"])
    }

    func test_deferredIdentifiersRoundTrip() {
        for section in MainMenuSection.allCases {
            XCTAssertEqual(MainMenuSection(deferredElementIdentifier: section.deferredElementIdentifier), section)
        }
        XCTAssertNil(MainMenuSection(deferredElementIdentifier: "other"))
    }

    // MARK: A-14 Pencil

    func test_pencilCommands() {
        XCTAssertEqual(pencilDrawingCommand(for: .switchEraser), .toggleEraser)
        XCTAssertEqual(pencilDrawingCommand(for: .switchPrevious), .toggleTools)
        XCTAssertEqual(pencilDrawingCommand(for: .showColorPalette), .showColorPicker)
        XCTAssertEqual(pencilDrawingCommand(for: .showInkAttributes), .showColorPicker)
        XCTAssertEqual(pencilDrawingCommand(for: .showContextualPalette), .showColorPicker)
        XCTAssertEqual(pencilDrawingCommand(for: .ignore), .none)
        XCTAssertEqual(pencilDrawingCommand(for: .runSystemShortcut), .none)
        XCTAssertEqual(pencilDrawingCommand(for: .unknown), .none)
    }

    func test_pencilOnlyDrawing() {
        XCTAssertTrue(drawingAcceptsTouch(isPencil: true, prefersPencilOnlyDrawing: true, deviceType: .tablet))
        XCTAssertFalse(drawingAcceptsTouch(isPencil: false, prefersPencilOnlyDrawing: true, deviceType: .tablet))
        XCTAssertTrue(drawingAcceptsTouch(isPencil: false, prefersPencilOnlyDrawing: false, deviceType: .tablet))
        // Phones: any touch draws, as upstream.
        XCTAssertTrue(drawingAcceptsTouch(isPencil: false, prefersPencilOnlyDrawing: true, deviceType: .phone))
    }

    func test_hoverPreview() {
        XCTAssertTrue(drawingShowsHoverPreview(deviceType: .tablet, isPencilHover: true, prefersHoverToolPreview: true))
        XCTAssertFalse(drawingShowsHoverPreview(deviceType: .tablet, isPencilHover: false, prefersHoverToolPreview: true))
        XCTAssertFalse(drawingShowsHoverPreview(deviceType: .tablet, isPencilHover: true, prefersHoverToolPreview: false))
        XCTAssertFalse(drawingShowsHoverPreview(deviceType: .phone, isPencilHover: true, prefersHoverToolPreview: true))
    }

    // MARK: B-7 Coalesced samples

    func test_coalescedTouches_tabletOnly() {
        XCTAssertTrue(drawingUsesCoalescedTouches(deviceType: .tablet))
        XCTAssertFalse(drawingUsesCoalescedTouches(deviceType: .phone))
    }

    func test_sampleBuffer_keepsSkippedSamplesForNextStep() {
        var buffer = DrawingSampleBuffer()
        buffer.append([CGPoint(x: 1, y: 1), CGPoint(x: 2, y: 2)])
        // A step the editor skipped (throttled): its samples stay.
        buffer.append([CGPoint(x: 3, y: 3), CGPoint(x: 4, y: 4)])
        XCTAssertEqual(buffer.drain(endingWith: CGPoint(x: 4, y: 4)), [CGPoint(x: 1, y: 1), CGPoint(x: 2, y: 2), CGPoint(x: 3, y: 3), CGPoint(x: 4, y: 4)])
        XCTAssertTrue(buffer.points.isEmpty)
        // Empty buffer: the event's own location.
        XCTAssertEqual(buffer.drain(endingWith: CGPoint(x: 5, y: 5)), [CGPoint(x: 5, y: 5)])
        // A buffer not ending at the current location gets it appended.
        buffer.append([CGPoint(x: 6, y: 6)])
        XCTAssertEqual(buffer.drain(endingWith: CGPoint(x: 7, y: 7)), [CGPoint(x: 6, y: 6), CGPoint(x: 7, y: 7)])
    }

    // MARK: A-8 Orientation lock

    func test_orientationLock_tablet() {
        XCTAssertFalse(windowPrefersInterfaceOrientationLocked(deviceType: .tablet, supportedOrientations: .all))
        XCTAssertTrue(windowPrefersInterfaceOrientationLocked(deviceType: .tablet, supportedOrientations: .landscape))
        XCTAssertTrue(windowPrefersInterfaceOrientationLocked(deviceType: .tablet, supportedOrientations: .portrait))
    }

    func test_orientationLock_phoneNever() {
        XCTAssertFalse(windowPrefersInterfaceOrientationLocked(deviceType: .phone, supportedOrientations: .portrait))
    }

    func test_sceneOrientation() {
        XCTAssertEqual(sceneInterfaceOrientation(deviceType: .tablet, legacy: .portrait, effectiveGeometry: .landscapeLeft), .landscapeLeft)
        XCTAssertEqual(sceneInterfaceOrientation(deviceType: .tablet, legacy: .portrait, effectiveGeometry: nil), .portrait)
        XCTAssertEqual(sceneInterfaceOrientation(deviceType: .phone, legacy: .portrait, effectiveGeometry: .landscapeLeft), .portrait)
    }
}
