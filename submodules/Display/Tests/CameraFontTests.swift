import XCTest
import UIKit
@testable import Display

// The camera design used to load a bundled Apple font. It must now be the system font.
final class CameraFontTests: XCTestCase {
    private func weightTrait(_ font: UIFont) -> CGFloat? {
        let traits = font.fontDescriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any]
        return (traits?[.weight] as? NSNumber).map { CGFloat($0.doubleValue) }
    }

    func test_cameraDesign_isSystemFontOfRequestedSizeAndWeight() {
        for (weight, systemWeight) in [(Font.Weight.regular, UIFont.Weight.regular), (.semibold, .semibold)] {
            for size: CGFloat in [13.0, 14.0, 21.0] {
                let font = Font.with(size: size, design: .camera, weight: weight)
                let system = UIFont.systemFont(ofSize: size, weight: systemWeight)
                XCTAssertEqual(font.pointSize, size)
                XCTAssertEqual(font.familyName, system.familyName)
                XCTAssertEqual(font.fontName, system.fontName)
                XCTAssertFalse(font.fontName.contains("SFCamera"))
                XCTAssertEqual(self.weightTrait(font) ?? 0.0, systemWeight.rawValue, accuracy: 0.01)
            }
        }
    }

    func test_cameraDesign_monospacedNumbersGivesEqualDigitWidths() {
        let font = Font.with(size: 17.0, design: .camera, weight: .semibold, traits: .monospacedNumbers)
        XCTAssertEqual(font.familyName, UIFont.systemFont(ofSize: 17.0).familyName)
        let widths = "0123456789".map { (String($0) as NSString).size(withAttributes: [.font: font]).width }
        XCTAssertEqual(Set(widths).count, 1)
    }
}
