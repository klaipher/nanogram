import XCTest
import UIKit
import UIKitRuntimeUtils
@testable import GlassBackgroundComponent

final class GlassFixedLookTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let name = "GlassFixedLookTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? UserDefaults()
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testNativeIsTheDefault() {
        XCTAssertFalse(GlassFixedLook.isRequested(in: self.makeDefaults()))
    }

    func testTheSwitchIsReadFromTheDefaultsKey() {
        let defaults = self.makeDefaults()
        GlassFixedLook.setRequested(true, in: defaults)
        XCTAssertTrue(GlassFixedLook.isRequested(in: defaults))
        XCTAssertTrue(defaults.bool(forKey: EffectSettingsContainerView.telegramFixedLookDefaultsKey))
        GlassFixedLook.setRequested(false, in: defaults)
        XCTAssertFalse(GlassFixedLook.isRequested(in: defaults))
    }

    /// The key is what the Debug Settings switch writes and +load reads; renaming it silently turns the switch off.
    func testTheKeyIsTheContract() {
        XCTAssertEqual(EffectSettingsContainerView.telegramFixedLookDefaultsKey, "nanogram.glass.telegramFixedLook")
    }

    /// The test host never sets the key, so +load must not have installed the luma clamp.
    func testTheClampIsNotInstalledByDefault() {
        XCTAssertFalse(EffectSettingsContainerView.isLumaClampInstalled)
        XCTAssertFalse(GlassFixedLook.isActive)
    }

    func testWithoutTheClampTheViewPassesEveryLumaThrough() {
        for isDark in [false, true] {
            let range = GlassFixedLook.lumaRange(isDark: isDark, clampInstalled: false)
            XCTAssertEqual(range.min, 0.0)
            XCTAssertEqual(range.max, 1.0)
        }
    }

    func testWithTheClampTheViewUsesTelegramsRanges() {
        for isDark in [false, true] {
            let range = GlassFixedLook.lumaRange(isDark: isDark, clampInstalled: true)
            let telegram = GlassBackgroundView.adaptiveLumaRange(isDark: isDark)
            XCTAssertEqual(range.min, telegram.min)
            XCTAssertEqual(range.max, telegram.max)
        }
    }

    func testTelegramsRangesStayInsideTheThemesSide() {
        let light = GlassBackgroundView.adaptiveLumaRange(isDark: false)
        let dark = GlassBackgroundView.adaptiveLumaRange(isDark: true)
        XCTAssertLessThanOrEqual(light.min, light.max)
        XCTAssertLessThanOrEqual(dark.min, dark.max)
        XCTAssertGreaterThan(light.min, dark.min)
    }
}
