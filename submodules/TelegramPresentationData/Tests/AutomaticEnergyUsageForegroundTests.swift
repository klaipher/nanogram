import XCTest
import UIKit
import SwiftSignalKit
import Display
import TelegramUIPreferences
@testable import TelegramPresentationData

final class AutomaticEnergyUsageForegroundTests: XCTestCase {
    private func spin() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }

    private func settings() -> MediaAutoDownloadSettings {
        var settings = MediaAutoDownloadSettings.defaultSettings
        settings.energyUsageSettings.activationThreshold = 15
        return settings
    }

    func test_returningToForeground_rereadsTheBatteryRule() {
        XCTAssertFalse(SystemEnergyConditionsMonitor.shared.observesSystemConditions)
        let center = NotificationCenter()
        var on = true
        var values: [Bool] = []
        let disposable = automaticEnergyUsageShouldBeOn(settings: self.settings(), notificationCenter: center, evaluate: { _ in on }).start(next: { values.append($0) })
        self.spin()
        XCTAssertEqual(values, [true])

        // Charged past the threshold while suspended: no battery notification came.
        on = false
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        self.spin()
        XCTAssertEqual(values, [true, false])

        on = true
        center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        self.spin()
        XCTAssertEqual(values, [true, false, true])

        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        self.spin()
        XCTAssertEqual(values, [true, false, true], "unchanged value is not repeated")
        disposable.dispose()
    }

    func test_systemObservingBranch_alsoRereadsOnForeground() {
        SystemEnergyConditionsMonitor.shared.observesSystemConditions = true
        defer { SystemEnergyConditionsMonitor.shared.observesSystemConditions = false }
        let center = NotificationCenter()
        var on = true
        var values: [Bool] = []
        let disposable = automaticEnergyUsageShouldBeOn(settings: self.settings(), notificationCenter: center, evaluate: { _ in on }).start(next: { values.append($0) })
        self.spin()
        XCTAssertEqual(values.last, true)

        on = false
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        self.spin()
        XCTAssertEqual(values.last, false)
        disposable.dispose()
    }

    func test_thresholdsOffAndAlways_areFixed() {
        var off = self.settings()
        off.energyUsageSettings.activationThreshold = 0
        var always = self.settings()
        always.energyUsageSettings.activationThreshold = 100
        var offValues: [Bool] = []
        var alwaysValues: [Bool] = []
        _ = automaticEnergyUsageShouldBeOn(settings: off, notificationCenter: NotificationCenter(), evaluate: { _ in true }).start(next: { offValues.append($0) })
        _ = automaticEnergyUsageShouldBeOn(settings: always, notificationCenter: NotificationCenter(), evaluate: { _ in false }).start(next: { alwaysValues.append($0) })
        XCTAssertEqual(offValues, [false])
        XCTAssertEqual(alwaysValues, [true])
    }
}
