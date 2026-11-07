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

    func testTelegramsLookIsTheDefault() {
        XCTAssertFalse(GlassFixedLook.isNativeRequested(in: self.makeDefaults()))
    }

    func testTheSwitchIsReadFromTheDefaultsKey() {
        let defaults = self.makeDefaults()
        GlassFixedLook.setNativeRequested(true, in: defaults)
        XCTAssertTrue(GlassFixedLook.isNativeRequested(in: defaults))
        XCTAssertTrue(defaults.bool(forKey: EffectSettingsContainerView.nativeNoClampDefaultsKey))
        GlassFixedLook.setNativeRequested(false, in: defaults)
        XCTAssertFalse(GlassFixedLook.isNativeRequested(in: defaults))
    }

    /// The key is what the Debug Settings switch writes and +load reads; renaming it silently turns the switch off.
    func testTheKeyIsTheContract() {
        XCTAssertEqual(EffectSettingsContainerView.nativeNoClampDefaultsKey, "nanogram.glass.nativeNoClamp")
    }

    /// The test host never sets the key, so +load must have installed the luma clamp (when UIKit's class is found, so
    /// only asserted where the host runs iOS 26 or later; the clamp is never installed with the switch on).
    func testTheClampIsInstalledByDefaultOnIOS26AndLater() {
        if #available(iOS 26.0, *) {
            XCTAssertTrue(EffectSettingsContainerView.isLumaClampInstalled)
            XCTAssertTrue(GlassFixedLook.isActive)
        } else {
            XCTAssertFalse(GlassFixedLook.isActive)
        }
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

    func testTelegramsRangesMatchUpstream13_2() {
        let dark = GlassBackgroundView.adaptiveLumaRange(isDark: true)
        XCTAssertEqual(dark.min, 0.0)
        XCTAssertEqual(dark.max, 0.874)
        let light = GlassBackgroundView.adaptiveLumaRange(isDark: false)
        XCTAssertEqual(light.max, 1.0)
        if #available(iOS 27.0, *) {
            XCTAssertEqual(light.min, 0.125)
        } else {
            XCTAssertEqual(light.min, 0.22)
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
