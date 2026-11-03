import Foundation
import UIKit

// A-14 and B-7 (iPadOS 27 audit, 2026-11-03): Apple Pencil in the photo/story drawing editor (DrawingUI). Pure
// decisions, tested by `//submodules/Display:TabletSystemTests`; `DrawingView` and `DrawingGesturePipeline` apply
// them. Pencil interactions never fire on a phone, and everything else here is gated on the tablet.

/// What a Pencil tap (any Pencil 2 or Pro) or squeeze (Pencil Pro) does in the drawing editor.
public enum PencilDrawingCommand: Equatable {
    case toggleEraser
    case toggleTools
    case showColorPicker
    case none
}

/// `UIPencilPreferredAction`, without its availability attributes.
public enum PencilPreferredAction: Equatable {
    case ignore
    case switchEraser
    case switchPrevious
    case showColorPalette
    case showInkAttributes
    case showContextualPalette
    case runSystemShortcut
    case unknown
}

/// Maps the user's system-wide Pencil preference (Settings ▸ Apple Pencil) to the editor. Upstream maps a tap's
/// eraser, previous-tool and colour palette preferences; the Pencil Pro's squeeze defaults to the contextual palette,
/// which in this editor is the colour picker, as are ink attributes. "Ignore" and system shortcuts (which the system
/// runs itself) do nothing here.
public func pencilDrawingCommand(for action: PencilPreferredAction) -> PencilDrawingCommand {
    switch action {
    case .switchEraser:
        return .toggleEraser
    case .switchPrevious:
        return .toggleTools
    case .showColorPalette, .showInkAttributes, .showContextualPalette:
        return .showColorPicker
    case .ignore, .runSystemShortcut, .unknown:
        return .none
    }
}

/// Whether a touch may draw. With "Only Draw with Apple Pencil" on (`UIPencilInteraction.prefersPencilOnlyDrawing`,
/// iOS 17.5) a finger does not draw on a tablet; it still pinches to zoom. Upstream drew with any touch.
public func drawingAcceptsTouch(isPencil: Bool, prefersPencilOnlyDrawing: Bool, deviceType: DeviceType) -> Bool {
    guard case .tablet = deviceType, prefersPencilOnlyDrawing else {
        return true
    }
    return isPencil
}

/// Whether the brush-size preview follows a hovering Pencil (M2 and later iPads): on a tablet, for Pencil hover
/// only (a trackpad pointer hovers too, at zero height), and unless the user turned "Show Hover Preview" off
/// (`UIPencilInteraction.prefersHoverToolPreview`, iOS 17.5).
public func drawingShowsHoverPreview(deviceType: DeviceType, isPencilHover: Bool, prefersHoverToolPreview: Bool) -> Bool {
    return deviceType == .tablet && isPencilHover && prefersHoverToolPreview
}

/// B-7: whether a stroke takes every touch sample the event coalesced (a Pencil reports up to 240 per second, a
/// 120 Hz screen delivers two to four per event). Upstream takes the event's last location only and then draws at
/// most one point per 16 ms. Tablet only.
public func drawingUsesCoalescedTouches(deviceType: DeviceType) -> Bool {
    return deviceType == .tablet
}

/// The touch samples of a stroke that have not been drawn yet, in order. The editor takes them all at once when it
/// accepts a step (`drain`), so samples from steps it skipped are drawn with the next one instead of lost.
public struct DrawingSampleBuffer: Equatable {
    public private(set) var points: [CGPoint] = []

    public init() {
    }

    public mutating func append(_ points: [CGPoint]) {
        self.points.append(contentsOf: points)
    }

    /// The pending samples, ending with `current` (the event's own location, which a coalesced list also ends
    /// with); empties the buffer.
    public mutating func drain(endingWith current: CGPoint) -> [CGPoint] {
        var result = self.points
        self.points.removeAll()
        if result.last != current {
            result.append(current)
        }
        return result
    }

    public mutating func reset() {
        self.points.removeAll()
    }
}
