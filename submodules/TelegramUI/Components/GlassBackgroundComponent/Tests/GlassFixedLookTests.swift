import XCTest
import UIKit
import UIKitRuntimeUtils
@testable import GlassBackgroundComponent

final class GlassFixedLookTests: XCTestCase {
    /// +load always installs the luma clamp where UIKit's class is found, so it is asserted where the host runs iOS 26
    /// or later.
    func testTheClampIsInstalledOnIOS26AndLater() {
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
