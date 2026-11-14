import Foundation
import UIKit
import AVFoundation

// iPad camera decisions from the iPadOS 27 audit (2026-11-03), second batch: A-8 (orientation in resizable windows),
// A-4 (system pressure is watched) and A-1 (front-camera rotation diagnostics). In the CameraMultitaskingPolicy module
// beside A-4's first half, so they are tested without the rest of Camera. Phones keep upstream's behaviour.

public enum CameraTabletPolicy {
    /// The interface orientation the camera preview follows: on an iPad with iOS 26, the scene's effective geometry
    /// (which follows a resizable window); else the deprecated `UIWindowScene.interfaceOrientation` upstream reads.
    public static func interfaceOrientation(isTablet: Bool, legacy: UIInterfaceOrientation, effectiveGeometry: UIInterfaceOrientation?) -> UIInterfaceOrientation {
        if isTablet, let effectiveGeometry, effectiveGeometry != .unknown {
            return effectiveGeometry
        }
        return legacy
    }

    /// `interfaceOrientation` for a window scene (portrait without one, as upstream).
    public static func interfaceOrientation(of scene: UIWindowScene?, isTablet: Bool = UIDevice.current.userInterfaceIdiom == .pad) -> UIInterfaceOrientation {
        guard let scene else {
            return .portrait
        }
        return CameraTabletPolicy.interfaceOrientation(isTablet: isTablet, legacy: scene.interfaceOrientation, effectiveGeometry: scene.effectiveGeometry.interfaceOrientation)
    }

    /// A-4: the log line for a change of a capture device's system pressure, or nil when it is not logged (phones;
    /// a repeat of the level already logged). Pressure is what interrupts a camera shared with another app in
    /// Stage Manager: at `shutdown` the system stops the session. The round-video recorder runs a fixed 30 fps clock
    /// (`VideoRecorder`), so the frame rate is not lowered here; the line tells the owner whether pressure explains
    /// an interruption seen on the device.
    public static func systemPressureMessage(isTablet: Bool, position: String, level: String, previousLevel: String?, factors: [String]) -> String? {
        guard isTablet, level != previousLevel else {
            return nil
        }
        let factorText = factors.isEmpty ? "none" : factors.joined(separator: ",")
        return "system pressure: position=\(position) level=\(level) factors=\(factorText)"
    }

    /// The name of a system pressure level for the log.
    public static func systemPressureLevelName(_ level: AVCaptureDevice.SystemPressureState.Level) -> String {
        switch level {
        case .nominal:
            return "nominal"
        case .fair:
            return "fair"
        case .serious:
            return "serious"
        case .critical:
            return "critical"
        case .shutdown:
            return "shutdown"
        default:
            return level.rawValue
        }
    }

    /// The names of the factors behind a system pressure state.
    public static func systemPressureFactorNames(_ factors: AVCaptureDevice.SystemPressureState.Factors) -> [String] {
        var names: [String] = []
        if factors.contains(.systemTemperature) {
            names.append("temperature")
        }
        if factors.contains(.peakPower) {
            names.append("peakPower")
        }
        if factors.contains(.depthModuleTemperature) {
            names.append("depthModuleTemperature")
        }
        if factors.contains(.cameraTemperature) {
            names.append("cameraTemperature")
        }
        return names
    }

    /// A-1: the log line describing how a front camera's video-data connection rotates its buffers, on an iPad only.
    /// Since the Spring 2024 iPads, a front camera's video-data connection defaults to 180° where earlier devices
    /// used 0° (`AVCaptureSession.h`, `videoRotationAngle`), and an app that rotates frames itself must account for
    /// it. Whether the in-app round video or the call camera comes out upside down cannot be told without that
    /// device; this line (connection angle, and the angle Apple's rotation coordinator asks for) is what the owner's
    /// one-minute check reads, before any rotation is changed.
    public static func rotationDiagnosticsMessage(isTablet: Bool, position: String, connectionAngle: Double, coordinatorCaptureAngle: Double?, coordinatorPreviewAngle: Double?) -> String? {
        guard isTablet else {
            return nil
        }
        func format(_ value: Double?) -> String {
            guard let value else {
                return "n/a"
            }
            return String(format: "%.0f", value)
        }
        return "rotation: position=\(position) connectionAngle=\(format(connectionAngle)) coordinatorCapture=\(format(coordinatorCaptureAngle)) coordinatorPreview=\(format(coordinatorPreviewAngle))"
    }
}
