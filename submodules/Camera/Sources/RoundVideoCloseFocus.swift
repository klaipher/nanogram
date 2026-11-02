import Foundation
import CoreGraphics
import AVFoundation

public extension Camera {
    /// Debug Settings ▸ "Circle Close Focus (Macro)" (`ExperimentalUISettings.videoMessageCloseFocus`), for the
    /// round-video camera (CameraNeo).
    ///
    /// The plain wide-angle camera cannot focus closer than its own minimum focus distance (around 20 cm on the
    /// 48 MP main cameras). With the switch on, the BACK camera opens as a virtual device that contains the
    /// ultra-wide (dual-wide first, then triple), with `primaryConstituentDeviceSwitchingBehavior` left at its
    /// default `.auto`, so iOS falls back to the ultra-wide (macro) for close subjects. On a virtual device
    /// `videoZoomFactor` 1.0 is the ultra-wide, so zoom is parked at the wide lens's switch-over factor
    /// ("neutral") and every zoom value is mapped relative to it, which keeps the framing identical to the plain
    /// wide at 1x. The front camera is never changed (its neutral factor is 1.0).
    ///
    /// With the switch off every function here returns what CameraNeo did before the switch existed
    /// (`RoundVideoCloseFocusTests`).
    enum RoundVideoCloseFocus {
        /// Device types to try, in order. The last is always today's `.builtInWideAngleCamera`, opened exactly as
        /// before (with its TrueDepth fallback).
        public static func preferredDeviceTypes(position: Camera.Position, closeFocus: Bool) -> [AVCaptureDevice.DeviceType] {
            if closeFocus && position == .back {
                // Dual-wide before triple: macro needs only the ultra-wide, and in a multi-cam session every
                // streaming sensor adds to the hardware cost, so a telephoto would be pure cost for a circle.
                return [.builtInDualWideCamera, .builtInTripleCamera, .builtInWideAngleCamera]
            }
            return [.builtInWideAngleCamera]
        }

        /// Whether a virtual (ultra-wide-containing) back device can be used. It needs a round-video format,
        /// and in a multi-cam session it must appear together with the front camera in one of the session's
        /// `supportedMultiCamDeviceSets`; otherwise the plain wide is used.
        public static func acceptsVirtualDevice(hasRoundVideoFormat: Bool, isMultiCam: Bool, pairsWithFrontInMultiCam: Bool) -> Bool {
            guard hasRoundVideoFormat else {
                return false
            }
            return !isMultiCam || pairsWithFrontInMultiCam
        }

        /// Whether one supported multi-cam device set holds both devices, matched by `uniqueID`.
        public static func multiCamDeviceSetsContainPair(_ sets: [Set<String>], _ first: String, _ second: String) -> Bool {
            guard first != second else {
                return false
            }
            return sets.contains { $0.contains(first) && $0.contains(second) }
        }

        /// The zoom factor at which a virtual device shows the wide-angle camera: the switch-over factor where
        /// the wide takes over from the wider constituent before it. 1.0 for a physical device, for a virtual
        /// device whose widest constituent is the wide (wide + tele), and for anything malformed.
        public static func neutralZoomFactor(constituentDeviceTypes: [AVCaptureDevice.DeviceType], switchOverZoomFactors: [CGFloat]) -> CGFloat {
            guard let wideIndex = constituentDeviceTypes.firstIndex(of: .builtInWideAngleCamera), wideIndex > 0 else {
                return 1.0
            }
            let switchOverIndex = wideIndex - 1
            guard switchOverIndex < switchOverZoomFactors.count else {
                return 1.0
            }
            let factor = switchOverZoomFactors[switchOverIndex]
            guard factor.isFinite, factor > 1.0 else {
                return 1.0
            }
            return factor
        }

        /// Clamps a zoom factor to what the device allows, never below the neutral factor. With a neutral
        /// factor of 1.0 this is the clamp CameraNeo always used.
        public static func clampedZoomFactor(_ value: CGFloat, neutral: CGFloat, minAvailable: CGFloat, maxAvailable: CGFloat) -> CGFloat {
            let minimum = max(neutral, minAvailable)
            let maximum = max(minimum, maxAvailable)
            return min(maximum, max(minimum, value))
        }

        /// The device zoom factor for a `rampZoom(_:rate:)` level (1.0 = the 1x framing).
        public static func zoomFactor(forRampLevel level: CGFloat, neutral: CGFloat) -> CGFloat {
            return level * neutral
        }

        /// The device zoom factor for a `setZoomLevel(_:)` offset (0.0 = the 1x framing).
        public static func zoomFactor(forLevelOffset offset: CGFloat, neutral: CGFloat) -> CGFloat {
            return neutral * (1.0 + offset)
        }

        /// `neutralZoomFactor` read from a capture device.
        public static func neutralZoomFactor(for device: AVCaptureDevice) -> CGFloat {
            guard device.isVirtualDevice else {
                return 1.0
            }
            return self.neutralZoomFactor(
                constituentDeviceTypes: device.constituentDevices.map(\.deviceType),
                switchOverZoomFactors: device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat($0.doubleValue) }
            )
        }
    }
}
