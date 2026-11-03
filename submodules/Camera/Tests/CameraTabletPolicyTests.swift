import XCTest
import UIKit
@testable import CameraMultitaskingPolicy

/// iPad camera decisions, second batch of the iPadOS 27 audit (A-8 orientation, A-4 pressure log, A-1 rotation
/// diagnostics). Phones keep upstream's behaviour.
final class CameraTabletPolicyTests: XCTestCase {
    func test_tablet_followsEffectiveGeometry() {
        XCTAssertEqual(CameraTabletPolicy.interfaceOrientation(isTablet: true, legacy: .portrait, effectiveGeometry: .landscapeRight), .landscapeRight)
        XCTAssertEqual(CameraTabletPolicy.interfaceOrientation(isTablet: true, legacy: .portrait, effectiveGeometry: nil), .portrait)
        XCTAssertEqual(CameraTabletPolicy.interfaceOrientation(isTablet: true, legacy: .landscapeLeft, effectiveGeometry: .unknown), .landscapeLeft)
    }

    func test_phone_keepsLegacyOrientation() {
        XCTAssertEqual(CameraTabletPolicy.interfaceOrientation(isTablet: false, legacy: .portrait, effectiveGeometry: .landscapeRight), .portrait)
        XCTAssertEqual(CameraTabletPolicy.interfaceOrientation(of: nil, isTablet: true), .portrait)
    }

    func test_pressure_loggedOnTabletOnChangeOnly() {
        XCTAssertEqual(
            CameraTabletPolicy.systemPressureMessage(isTablet: true, position: "front", level: "serious", previousLevel: "nominal", factors: ["temperature", "peakPower"]),
            "system pressure: position=front level=serious factors=temperature,peakPower"
        )
        XCTAssertNil(CameraTabletPolicy.systemPressureMessage(isTablet: true, position: "front", level: "serious", previousLevel: "serious", factors: []))
        XCTAssertNil(CameraTabletPolicy.systemPressureMessage(isTablet: false, position: "front", level: "critical", previousLevel: nil, factors: []))
    }

    func test_pressureNames() {
        XCTAssertEqual(CameraTabletPolicy.systemPressureLevelName(.shutdown), "shutdown")
        XCTAssertEqual(CameraTabletPolicy.systemPressureFactorNames([.systemTemperature, .peakPower]), ["temperature", "peakPower"])
        XCTAssertEqual(CameraTabletPolicy.systemPressureFactorNames([]), [])
    }

    func test_rotationDiagnostics_tabletOnly() {
        XCTAssertEqual(
            CameraTabletPolicy.rotationDiagnosticsMessage(isTablet: true, position: "front", connectionAngle: 180.0, coordinatorCaptureAngle: 90.0, coordinatorPreviewAngle: nil),
            "rotation: position=front connectionAngle=180 coordinatorCapture=90 coordinatorPreview=n/a"
        )
        XCTAssertNil(CameraTabletPolicy.rotationDiagnosticsMessage(isTablet: false, position: "front", connectionAngle: 0.0, coordinatorCaptureAngle: nil, coordinatorPreviewAngle: nil))
    }
}
