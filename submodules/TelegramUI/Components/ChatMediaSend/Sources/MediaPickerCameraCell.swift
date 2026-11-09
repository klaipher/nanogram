import Foundation
import UIKit
import Display

public enum MediaPickerCameraCellSubject {
    case chatAssets
    case sticker
    case avatar
    case other
    case noCamera
}

public enum MediaPickerCameraCellBranch: Equatable {
    case none
    case legacyAttachmentCamera
    case chatCamera
    case editorCamera
}

public func mediaPickerCameraCellBranch(flagOn: Bool, subject: MediaPickerCameraCellSubject, isIpad: Bool, isSimulator: Bool) -> MediaPickerCameraCellBranch {
    switch subject {
    case .chatAssets:
        return flagOn ? .chatCamera : .legacyAttachmentCamera
    case .sticker, .avatar:
        return (isIpad || isSimulator) ? .none : .editorCamera
    case .other, .noCamera:
        return .none
    }
}

public func mediaPickerRequestsCameraAccess(subject: MediaPickerCameraCellSubject) -> Bool {
    return subject != .noCamera
}

public func mediaPickerCameraCellPreviewSize(branch: MediaPickerCameraCellBranch, layoutWidth: CGFloat, screenWidth: CGFloat) -> CGSize {
    switch branch {
    case .chatCamera:
        return CGSize(width: screenWidth, height: floorToScreenPixels(screenWidth * 4.0 / 3.0))
    case .none, .legacyAttachmentCamera, .editorCamera:
        return CGSize(width: screenWidth, height: floorToScreenPixels(layoutWidth * 1.77778))
    }
}

public enum MediaPickerCameraCellCaptureAction: Equatable {
    case none
    case start
    case stop
}

/// What the chat camera tile does when the full-screen camera takes over its camera and preview view.
public struct MediaPickerChatCameraHandOff: Equatable {
    public var enablesPreview: Bool
    public var startsCapture: Bool

    public init(enablesPreview: Bool, startsCapture: Bool) {
        self.enablesPreview = enablesPreview
        self.startsCapture = startsCapture
    }
}

/// Without a live preview in the tile (Power Saving), the tile has disabled its preview connection and stopped the
/// camera. The full-screen camera keeps the same preview view and never enables it again, so the hand-off does: else
/// the camera runs (green indicator on) behind a frozen picture.
public func mediaPickerChatCameraHandOff(hasLivePreview: Bool) -> MediaPickerChatCameraHandOff {
    return MediaPickerChatCameraHandOff(enablesPreview: true, startsCapture: !hasLivePreview)
}

public func mediaPickerChatCameraCellCaptureAction(isActive: Bool, hasLivePreview: Bool, isInvalidated: Bool, isInWindow: Bool, isHandedOff: Bool) -> MediaPickerCameraCellCaptureAction {
    if isHandedOff {
        return .none
    }
    if isActive && hasLivePreview && !isInvalidated && isInWindow {
        return .start
    }
    return .stop
}
