import XCTest
import UIKit
@testable import GlassBackgroundComponent

final class GlassAccessibilityTests: XCTestCase {
    private func components(_ color: UIColor) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        var r: CGFloat = 0.0, g: CGFloat = 0.0, b: CGFloat = 0.0, a: CGFloat = 0.0
        XCTAssertTrue(color.getRed(&r, green: &g, blue: &b, alpha: &a))
        return (r, g, b, a)
    }

    func testStandardStateChangesNothing() {
        let fill = UIColor(white: 1.0, alpha: 0.7)
        let result = GlassAccessibility.legacyFill(fillColor: fill, borderWidthFactor: 1.0, isDark: false, state: .standard)
        XCTAssertEqual(self.components(result.fillColor).a, 0.7, accuracy: 0.0001)
        XCTAssertEqual(result.borderWidthFactor, 1.0)
        let clear = GlassAccessibility.legacyFill(fillColor: UIColor(white: 1.0, alpha: 0.0), borderWidthFactor: 2.0, isDark: true, state: .standard)
        XCTAssertEqual(self.components(clear.fillColor).a, 0.0, accuracy: 0.0001)
        XCTAssertEqual(clear.borderWidthFactor, 2.0)
    }

    func testReduceTransparencyMakesTheFillOpaque() {
        let state = GlassAccessibilityState(reduceTransparency: true, increaseContrast: false)
        for isDark in [false, true] {
            for alpha in [0.0, 0.3, 0.7, 0.85, 1.0] as [CGFloat] {
                let result = GlassAccessibility.legacyFill(fillColor: UIColor(white: 0.5, alpha: alpha), borderWidthFactor: 1.0, isDark: isDark, state: state)
                XCTAssertEqual(self.components(result.fillColor).a, 1.0, accuracy: 0.0001)
            }
        }
    }

    /// A translucent accent keeps its look: it is laid over the appearance's base rather than made fully saturated.
    func testReduceTransparencyCompositesOverTheBase() {
        let state = GlassAccessibilityState(reduceTransparency: true, increaseContrast: false)
        let accent = UIColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 0.5)
        let light = self.components(GlassAccessibility.legacyFill(fillColor: accent, borderWidthFactor: 1.0, isDark: false, state: state).fillColor)
        XCTAssertEqual(light.r, 1.0, accuracy: 0.001)
        XCTAssertEqual(light.g, 0.5, accuracy: 0.001)
        XCTAssertEqual(light.b, 0.5, accuracy: 0.001)
        let dark = self.components(GlassAccessibility.legacyFill(fillColor: accent, borderWidthFactor: 1.0, isDark: true, state: state).fillColor)
        XCTAssertEqual(dark.r, 0.5 + 0.11 * 0.5, accuracy: 0.001)
        XCTAssertEqual(dark.g, 0.11 * 0.5, accuracy: 0.001)
    }

    func testClearGlassBecomesTheSolidBase() {
        let state = GlassAccessibilityState(reduceTransparency: true, increaseContrast: false)
        let light = self.components(GlassAccessibility.legacyFill(fillColor: UIColor(white: 1.0, alpha: 0.0), borderWidthFactor: 2.0, isDark: false, state: state).fillColor)
        XCTAssertEqual(light.r, 1.0, accuracy: 0.001)
        let dark = self.components(GlassAccessibility.legacyFill(fillColor: UIColor(white: 1.0, alpha: 0.0), borderWidthFactor: 2.0, isDark: true, state: state).fillColor)
        XCTAssertEqual(dark.r, 0.11, accuracy: 0.001)
    }

    func testIncreaseContrastDoublesTheEdgeOnly() {
        let state = GlassAccessibilityState(reduceTransparency: false, increaseContrast: true)
        let result = GlassAccessibility.legacyFill(fillColor: UIColor(white: 1.0, alpha: 0.7), borderWidthFactor: 1.0, isDark: false, state: state)
        XCTAssertEqual(result.borderWidthFactor, 2.0)
        XCTAssertEqual(self.components(result.fillColor).a, 0.7, accuracy: 0.0001)
    }

    func testCustomBlurRadiusIsDroppedUnderReduceTransparency() {
        XCTAssertEqual(GlassAccessibility.effectiveBlurRadius(requested: 12.0, state: .standard), 12.0)
        XCTAssertNil(GlassAccessibility.effectiveBlurRadius(requested: nil, state: .standard))
        XCTAssertNil(GlassAccessibility.effectiveBlurRadius(requested: 12.0, state: GlassAccessibilityState(reduceTransparency: true, increaseContrast: false)))
        XCTAssertEqual(GlassAccessibility.effectiveBlurRadius(requested: 12.0, state: GlassAccessibilityState(reduceTransparency: false, increaseContrast: true)), 12.0)
    }

    /// The view reapplies when the environment changes, and does so with no params yet.
    func testViewsSurviveTheEnvironmentNotification() {
        let view = GlassBackgroundView()
        NotificationCenter.default.post(name: GlassEnvironment.didChangeNotification, object: nil)
        view.update(size: CGSize(width: 40.0, height: 40.0), cornerRadius: 20.0, isDark: false, tintColor: .init(kind: .panel), transition: .immediate)
        NotificationCenter.default.post(name: GlassEnvironment.didChangeNotification, object: nil)
        XCTAssertEqual(view.params?.isDark, false)
    }
}
