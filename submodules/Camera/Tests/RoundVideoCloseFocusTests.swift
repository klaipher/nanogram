import XCTest
import AVFoundation
import Camera

/// Pins the decisions behind Debug Settings ▸ "Circle Close Focus (Macro)".
///
/// With the switch on, the round-video camera opens the back camera as a virtual device that contains the
/// ultra-wide, so iOS can switch to it for close subjects, and parks zoom at the wide lens's switch-over factor
/// so the picture is framed exactly as before. With the switch off nothing may change: the same device type is
/// opened and every zoom value maps to the same factor as before the switch existed. The pre-switch formulas
/// are restated here (`legacy…`) and compared value by value.
final class RoundVideoCloseFocusTests: XCTestCase {
    private typealias Policy = Camera.RoundVideoCloseFocus

    // The formulas CameraNeo used before the switch existed.
    private func legacyClampedZoom(_ value: CGFloat, minAvailable: CGFloat, maxAvailable: CGFloat) -> CGFloat {
        let minimum = max(1.0, minAvailable)
        let maximum = max(minimum, maxAvailable)
        return min(maximum, max(minimum, value))
    }

    private func legacyZoomLevel(_ zoomLevel: CGFloat) -> CGFloat {
        return 1.0 + zoomLevel
    }

    private let sampleValues: [CGFloat] = [0.0, 0.25, 0.5, 0.99, 1.0, 1.5, 2.0, 3.0, 6.0, 10.0, 100.0, 200.0]

    // MARK: - Device choice

    func testSwitchOffOpensTheWideAngleCameraAtBothPositions() {
        XCTAssertEqual(Policy.preferredDeviceTypes(position: .back, closeFocus: false), [.builtInWideAngleCamera])
        XCTAssertEqual(Policy.preferredDeviceTypes(position: .front, closeFocus: false), [.builtInWideAngleCamera])
        XCTAssertEqual(Policy.preferredDeviceTypes(position: .unspecified, closeFocus: false), [.builtInWideAngleCamera])
    }

    func testSwitchOnPrefersDualWideThenTripleThenWideForTheBackCamera() {
        XCTAssertEqual(
            Policy.preferredDeviceTypes(position: .back, closeFocus: true),
            [.builtInDualWideCamera, .builtInTripleCamera, .builtInWideAngleCamera]
        )
    }

    func testSwitchOnLeavesTheFrontCameraAlone() {
        XCTAssertEqual(Policy.preferredDeviceTypes(position: .front, closeFocus: true), [.builtInWideAngleCamera])
    }

    func testEveryPreferredListEndsWithTodaysWideAngleCamera() {
        for position: Camera.Position in [.back, .front, .unspecified] {
            for closeFocus in [false, true] {
                XCTAssertEqual(Policy.preferredDeviceTypes(position: position, closeFocus: closeFocus).last, .builtInWideAngleCamera)
            }
        }
    }

    func testVirtualDeviceNeedsARoundVideoFormat() {
        XCTAssertFalse(Policy.acceptsVirtualDevice(hasRoundVideoFormat: false, isMultiCam: false, pairsWithFrontInMultiCam: false))
        XCTAssertTrue(Policy.acceptsVirtualDevice(hasRoundVideoFormat: true, isMultiCam: false, pairsWithFrontInMultiCam: false))
    }

    func testVirtualDeviceInMultiCamNeedsASupportedDeviceSetWithTheFrontCamera() {
        XCTAssertFalse(Policy.acceptsVirtualDevice(hasRoundVideoFormat: true, isMultiCam: true, pairsWithFrontInMultiCam: false))
        XCTAssertTrue(Policy.acceptsVirtualDevice(hasRoundVideoFormat: true, isMultiCam: true, pairsWithFrontInMultiCam: true))
        XCTAssertFalse(Policy.acceptsVirtualDevice(hasRoundVideoFormat: false, isMultiCam: true, pairsWithFrontInMultiCam: true))
    }

    func testMultiCamDeviceSetsAreMatchedByUniqueID() {
        let sets: [Set<String>] = [["wide", "front"], ["ultra", "front"], ["dualwide", "tele"]]
        XCTAssertTrue(Policy.multiCamDeviceSetsContainPair(sets, "wide", "front"))
        XCTAssertTrue(Policy.multiCamDeviceSetsContainPair(sets, "front", "ultra"))
        XCTAssertFalse(Policy.multiCamDeviceSetsContainPair(sets, "dualwide", "front"))
        XCTAssertFalse(Policy.multiCamDeviceSetsContainPair([], "wide", "front"))
        XCTAssertFalse(Policy.multiCamDeviceSetsContainPair(sets, "wide", "wide"))
    }

    // MARK: - Neutral zoom factor

    func testPhysicalDeviceHasNeutralFactorOne() {
        XCTAssertEqual(Policy.neutralZoomFactor(constituentDeviceTypes: [], switchOverZoomFactors: []), 1.0)
    }

    func testDualWideNeutralFactorIsTheWideSwitchOverFactor() {
        XCTAssertEqual(Policy.neutralZoomFactor(
            constituentDeviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera],
            switchOverZoomFactors: [2.0]
        ), 2.0)
    }

    func testNeutralFactorIsReadFromTheDeviceNotHardCoded() {
        XCTAssertEqual(Policy.neutralZoomFactor(
            constituentDeviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera],
            switchOverZoomFactors: [1.8]
        ), 1.8)
    }

    func testTripleNeutralFactorIsTheFirstSwitchOverFactor() {
        XCTAssertEqual(Policy.neutralZoomFactor(
            constituentDeviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera],
            switchOverZoomFactors: [2.0, 8.0]
        ), 2.0)
    }

    func testDeviceWithoutUltraWideHasNeutralFactorOne() {
        // builtInDualCamera (wide + tele): 1.0 is already the wide.
        XCTAssertEqual(Policy.neutralZoomFactor(
            constituentDeviceTypes: [.builtInWideAngleCamera, .builtInTelephotoCamera],
            switchOverZoomFactors: [2.0]
        ), 1.0)
    }

    func testMalformedSwitchOverFactorsFallBackToOne() {
        XCTAssertEqual(Policy.neutralZoomFactor(
            constituentDeviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera],
            switchOverZoomFactors: []
        ), 1.0)
        XCTAssertEqual(Policy.neutralZoomFactor(
            constituentDeviceTypes: [.builtInUltraWideCamera, .builtInTelephotoCamera],
            switchOverZoomFactors: [2.0]
        ), 1.0)
        XCTAssertEqual(Policy.neutralZoomFactor(
            constituentDeviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera],
            switchOverZoomFactors: [0.5]
        ), 1.0)
        XCTAssertEqual(Policy.neutralZoomFactor(
            constituentDeviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera],
            switchOverZoomFactors: [.nan]
        ), 1.0)
    }

    // MARK: - Zoom mapping

    func testNeutralOneClampIsTodaysClamp() {
        for value in self.sampleValues {
            for minAvailable: CGFloat in [0.5, 1.0, 2.0] {
                for maxAvailable: CGFloat in [1.0, 16.0, 123.75] {
                    XCTAssertEqual(
                        Policy.clampedZoomFactor(value, neutral: 1.0, minAvailable: minAvailable, maxAvailable: maxAvailable),
                        self.legacyClampedZoom(value, minAvailable: minAvailable, maxAvailable: maxAvailable),
                        "value \(value), min \(minAvailable), max \(maxAvailable)"
                    )
                }
            }
        }
    }

    func testNeutralOneLevelsAreTodaysLevels() {
        for value in self.sampleValues {
            XCTAssertEqual(Policy.zoomFactor(forRampLevel: value, neutral: 1.0), value)
            XCTAssertEqual(Policy.zoomFactor(forLevelOffset: value, neutral: 1.0), self.legacyZoomLevel(value))
        }
    }

    func testClampNeverGoesBelowTheNeutralFactor() {
        // A virtual device reports minAvailable 1.0, which is the ultra-wide (0.5x).
        XCTAssertEqual(Policy.clampedZoomFactor(1.0, neutral: 2.0, minAvailable: 1.0, maxAvailable: 123.75), 2.0)
        XCTAssertEqual(Policy.clampedZoomFactor(0.5, neutral: 2.0, minAvailable: 1.0, maxAvailable: 123.75), 2.0)
        XCTAssertEqual(Policy.clampedZoomFactor(3.0, neutral: 2.0, minAvailable: 1.0, maxAvailable: 123.75), 3.0)
        XCTAssertEqual(Policy.clampedZoomFactor(500.0, neutral: 2.0, minAvailable: 1.0, maxAvailable: 123.75), 123.75)
        // A device that cannot go below its own minimum keeps it.
        XCTAssertEqual(Policy.clampedZoomFactor(1.0, neutral: 2.0, minAvailable: 2.5, maxAvailable: 10.0), 2.5)
        // A maximum below the minimum collapses to the minimum.
        XCTAssertEqual(Policy.clampedZoomFactor(5.0, neutral: 2.0, minAvailable: 1.0, maxAvailable: 1.5), 2.0)
    }

    func testPinchReleaseReturnsToTheNeutralFraming() {
        // VideoMessageCameraScreen ramps to 1.0 when a pinch ends: that must be 1x framing, not the ultra-wide.
        XCTAssertEqual(Policy.zoomFactor(forRampLevel: 1.0, neutral: 2.0), 2.0)
        XCTAssertEqual(Policy.zoomFactor(forRampLevel: 2.0, neutral: 2.0), 4.0)
        XCTAssertEqual(Policy.zoomFactor(forLevelOffset: 0.0, neutral: 2.0), 2.0)
        XCTAssertEqual(Policy.zoomFactor(forLevelOffset: 1.0, neutral: 2.0), 4.0)
    }
}
