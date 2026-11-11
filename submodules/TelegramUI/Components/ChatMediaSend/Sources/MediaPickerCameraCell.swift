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

/// The full-screen camera keeps the tile's camera and preview view and starts neither, so the hand-off makes both run.
/// `tileCaptureState` is what the tile last asked its camera to do: `true` started, `false` stopped, `nil` nothing yet.
/// The tile stops its camera (and disables the preview connection) whenever it is not visible: with Power Saving it never
/// runs, and when the picker opens it is stopped until the tile is on screen, which takes up to ~2 s. A tap in that time
/// handed a stopped camera to the full-screen screen, which showed a still frame. Starting an already running camera is
/// a no-op, so only the tile's own start is trusted.
public func mediaPickerChatCameraHandOff(tileCaptureState: Bool?) -> MediaPickerChatCameraHandOff {
    return MediaPickerChatCameraHandOff(enablesPreview: true, startsCapture: tileCaptureState != true)
}

/// Whether the chat camera tile creates its `Camera` now. Creating it is a blocking IPC (about 7 ms on the main thread), so the
/// tile does not do it at every picker open: only when the tile wants to run it (active, on screen, live preview on), or when
/// a tap needs a running camera for the full-screen hand-off (also in Power Saving, where the tile never runs it).
public func mediaPickerChatCameraShouldCreateNow(hasCamera: Bool, isInvalidated: Bool, hasLivePreview: Bool, tileActive: Bool, tapped: Bool) -> Bool {
    if hasCamera || isInvalidated {
        return false
    }
    if tapped {
        return true
    }
    return hasLivePreview && tileActive
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
