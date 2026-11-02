import Foundation
import UIKit
import AVFoundation
import CoreMedia
import CoreVideo
import DeviceModel
import Camera

let roundVideoCaptureFrameRate: Double = 30.0

enum RoundVideoCaptureProfile: Int, CaseIterable {
    // Budget tiers: rear uses 16:9, front uses 4:3 to retain its field of view.
    case high
    case medium
    case vga

    init?(width: Int32, height: Int32, position: AVCaptureDevice.Position) {
        switch (position, width, height) {
        case (.back, 1920, 1080), (.front, 1920, 1440): self = .high
        case (.back, 1280, 720), (.front, 1280, 960): self = .medium
        case (_, 640, 480): self = .vga
        default: return nil
        }
    }
}

private struct RoundVideoCaptureFormatCandidate {
    let profile: RoundVideoCaptureProfile?
    let isNV12: Bool
    let frameRateRanges: [ClosedRange<Double>]
    let supportsMultiCam: Bool
    let supportsStandardStabilization: Bool
}

private func selectRoundVideoCaptureFormat(
    _ candidates: [RoundVideoCaptureFormatCandidate],
    requiresMultiCam: Bool,
    preferStabilization: Bool,
    preferMediumProfile: Bool,
    maximumProfile: RoundVideoCaptureProfile = .high
) -> Int? {
    let eligible = candidates.indices.filter { index in
        let candidate = candidates[index]
        guard let profile = candidate.profile, profile.rawValue >= maximumProfile.rawValue else {
            return false
        }
        return candidate.isNV12
            && (!requiresMultiCam || candidate.supportsMultiCam)
            && candidate.frameRateRanges.contains(where: { $0.contains(roundVideoCaptureFrameRate) })
    }
    return eligible.min { lhsIndex, rhsIndex in
        let lhs = candidates[lhsIndex]
        let rhs = candidates[rhsIndex]
        if preferStabilization, lhs.supportsStandardStabilization != rhs.supportsStandardStabilization {
            return lhs.supportsStandardStabilization
        }
        if lhs.profile != rhs.profile {
            if preferMediumProfile {
                if lhs.profile == .medium {
                    return true
                }
                if rhs.profile == .medium {
                    return false
                }
            }
            return lhs.profile!.rawValue < rhs.profile!.rawValue
        }
        let lhsMaximumFps = lhs.frameRateRanges.map(\.upperBound).max() ?? 0.0
        let rhsMaximumFps = rhs.frameRateRanges.map(\.upperBound).max() ?? 0.0
        if lhsMaximumFps != rhsMaximumFps {
            return lhsMaximumFps < rhsMaximumFps
        }
        return lhsIndex < rhsIndex
    }
}

func roundVideoCaptureCostsAreSupported(hardwareCost: Float, systemPressureCost: Float) -> Bool {
    return hardwareCost.isFinite && systemPressureCost.isFinite
        && hardwareCost <= 1.0 && systemPressureCost <= 1.0
}

func roundVideoCaptureFormat(
    for device: AVCaptureDevice,
    requiresMultiCam: Bool,
    mode: NeoCameraImpl.RoundVideoMode,
    maximumProfile: RoundVideoCaptureProfile = .high
) -> AVCaptureDevice.Format? {
    let formats = device.formats
    let candidates = formats.map { format -> RoundVideoCaptureFormatCandidate in
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription)
        let supportsMultiCam: Bool
        if #available(iOS 13.0, *) {
            supportsMultiCam = format.isMultiCamSupported
        } else {
            supportsMultiCam = false
        }
        return RoundVideoCaptureFormatCandidate(
            profile: RoundVideoCaptureProfile(width: dimensions.width, height: dimensions.height, position: device.position),
            isNV12: subtype == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange || subtype == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            frameRateRanges: format.videoSupportedFrameRateRanges.map { $0.minFrameRate ... $0.maxFrameRate },
            supportsMultiCam: supportsMultiCam,
            supportsStandardStabilization: format.isVideoStabilizationModeSupported(.standard)
        )
    }
    guard let index = selectRoundVideoCaptureFormat(
        candidates,
        requiresMultiCam: requiresMultiCam,
        preferStabilization: mode != .vga && device.position == .back,
        preferMediumProfile: device.position == .front,
        maximumProfile: mode == .vga ? .vga : maximumProfile
    ) else {
        return nil
    }
    return formats[index]
}

/// The camera a round video opens at a position without the close-focus switch: the wide-angle camera, or
/// whatever wide-angle/TrueDepth camera exists there.
func defaultRoundVideoCaptureDevice(position: AVCaptureDevice.Position) -> AVCaptureDevice? {
    if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) {
        return device
    }
    return AVCaptureDevice.DiscoverySession(
        deviceTypes: [.builtInWideAngleCamera, .builtInTrueDepthCamera],
        mediaType: .video,
        position: position
    ).devices.first
}

/// The virtual back camera (with the ultra-wide) that Debug Settings ▸ "Circle Close Focus (Macro)" opens, or nil
/// when the switch is off, the position is not the back, or no virtual device qualifies; the caller then opens
/// `defaultRoundVideoCaptureDevice` exactly as without the switch. The dual-camera probe and the session both
/// call this, so dual support is never reported for a pair the session then cannot build.
func closeFocusRoundVideoCaptureDevice(
    position: AVCaptureDevice.Position,
    closeFocus: Bool,
    multiCam: Bool,
    mode: NeoCameraImpl.RoundVideoMode
) -> AVCaptureDevice? {
    let deviceTypes = Camera.RoundVideoCloseFocus.preferredDeviceTypes(position: position, closeFocus: closeFocus)
        .filter { $0 != .builtInWideAngleCamera }
    guard !deviceTypes.isEmpty else {
        return nil
    }
    var multiCamDeviceSets: [Set<String>] = []
    var frontDeviceId: String?
    if multiCam {
        guard #available(iOS 13.0, *), let frontDevice = defaultRoundVideoCaptureDevice(position: .front) else {
            return nil
        }
        frontDeviceId = frontDevice.uniqueID
        multiCamDeviceSets = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes + [.builtInWideAngleCamera, .builtInTrueDepthCamera],
            mediaType: .video,
            position: .unspecified
        ).supportedMultiCamDeviceSets.map { Set($0.map(\.uniqueID)) }
    }
    for deviceType in deviceTypes {
        guard let device = AVCaptureDevice.default(deviceType, for: .video, position: position) else {
            continue
        }
        let pairsWithFront = frontDeviceId.flatMap { frontDeviceId in
            Camera.RoundVideoCloseFocus.multiCamDeviceSetsContainPair(multiCamDeviceSets, device.uniqueID, frontDeviceId)
        } ?? false
        if Camera.RoundVideoCloseFocus.acceptsVirtualDevice(
            hasRoundVideoFormat: roundVideoCaptureFormat(for: device, requiresMultiCam: multiCam, mode: mode) != nil,
            isMultiCam: multiCam,
            pairsWithFrontInMultiCam: pairsWithFront
        ) {
            return device
        }
    }
    return nil
}

private func supportsDualCameraCapture(forRoundVideo: Bool, mode: NeoCameraImpl.RoundVideoMode, closeFocus: Bool) -> Bool {
    guard #available(iOS 13.0, *), AVCaptureMultiCamSession.isMultiCamSupported, !DeviceModel.current.isIpad else {
        return false
    }
    if forRoundVideo && DeviceModel.current == .iPhoneXR {
        return false
    }
    let positions: [AVCaptureDevice.Position] = [.back, .front]
    return positions.allSatisfy { position in
        // The same back camera the session will open. A virtual one qualifies only with a multi-cam format,
        // so without one this is exactly the wide-angle check below.
        if forRoundVideo, closeFocusRoundVideoCaptureDevice(position: position, closeFocus: closeFocus, multiCam: true, mode: mode) != nil {
            return true
        }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else {
            return false
        }
        return roundVideoCaptureFormat(for: device, requiresMultiCam: true, mode: mode) != nil
    }
}

public final class NeoCameraImpl: CameraImpl {
    public enum RoundVideoMode: String {
        case vga
        case hdBilinear
        case hdLanczos
    }

    /// Debug Settings ▸ "Circle Colour Decode": the YCbCr matrix the processor decodes the camera's 8-bit 4:2:0
    /// frames with (`RoundVideoFrameProcessor.decodeMatrix`). The camera tags them BT.601, but they match the
    /// camera's own BGRA conversion (Legacy, the official app) only when decoded as BT.709. `.cameraTag` is the
    /// behaviour before the setting existed. A BT.2020 tag is always followed.
    public enum RoundVideoCameraMatrix: String {
        case bt709
        case cameraTag
        case bt601
    }

    public static let shared = NeoCameraImpl()

    private let roundVideoMode: RoundVideoMode
    private let closeFocus: Bool
    private let cameraMatrix: RoundVideoCameraMatrix
    private let log: ((String) -> Void)?

    /// `closeFocus`: Debug Settings ▸ "Circle Close Focus (Macro)" (`Camera.RoundVideoCloseFocus`). Off, the
    /// camera behaves exactly as before the switch existed.
    public init(roundVideoMode: RoundVideoMode = .hdBilinear, closeFocus: Bool = false, cameraMatrix: RoundVideoCameraMatrix = .bt709, log: ((String) -> Void)? = nil) {
        self.roundVideoMode = roundVideoMode
        self.closeFocus = closeFocus
        self.cameraMatrix = cameraMatrix
        self.log = log
        RoundVideoDecorationProvider.shared.warmUp()
    }

    public var isIpad: Bool {
        return DeviceModel.current.isIpad
    }

    public func isDualCameraSupported(forRoundVideo: Bool) -> Bool {
        return supportsDualCameraCapture(forRoundVideo: forRoundVideo, mode: self.roundVideoMode, closeFocus: self.closeFocus)
    }

    public func makeCamera(
        configuration: Camera.Configuration,
        previewView: CameraSimplePreviewView?,
        secondaryPreviewView: CameraSimplePreviewView?
    ) -> CameraProtocol {
        let cameraPreviewView: CameraPreviewView?
        if let previewView {
            guard let previewView = previewView as? CameraPreviewView else {
                preconditionFailure()
            }
            cameraPreviewView = previewView
        } else {
            cameraPreviewView = nil
        }

        let cameraSecondaryPreviewView: CameraPreviewView?
        if let secondaryPreviewView {
            guard let secondaryPreviewView = secondaryPreviewView as? CameraPreviewView else {
                preconditionFailure()
            }
            cameraSecondaryPreviewView = secondaryPreviewView
        } else {
            cameraSecondaryPreviewView = nil
        }

        return CameraNeo(
            configuration: configuration,
            previewView: cameraPreviewView,
            secondaryPreviewView: cameraSecondaryPreviewView,
            useMultiCam: configuration.isDualEnabled && self.isDualCameraSupported(forRoundVideo: configuration.isRoundVideo),
            roundVideoMode: self.roundVideoMode,
            closeFocus: self.closeFocus && configuration.isRoundVideo,
            cameraMatrix: self.cameraMatrix,
            log: self.log
        )
    }

    public func makeCameraSimplePreviewView(frame: CGRect, main: Bool, roundVideo: Bool) -> CameraSimplePreviewView {
        return CameraPreviewView(frame: frame, main: main, roundVideo: roundVideo)
    }
}
