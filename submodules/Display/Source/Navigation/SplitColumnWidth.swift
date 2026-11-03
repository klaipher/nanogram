import Foundation
import UIKit

// The resizable chat-list column (iPad split view). Nanogram-only: upstream Telegram iOS has a fixed column.
// Everything here is pure (or, for the store, takes its UserDefaults), so that `NavigationSplitContainer`
// changes by a call each and the rules are unit-tested (`//submodules/Display:SplitColumnWidthTests`).

/// The window shape a column width is remembered for.
public enum SplitColumnShape: String, CaseIterable {
    case landscape
    case portrait

    public init(containerSize: CGSize) {
        self = containerSize.width > containerSize.height ? .landscape : .portrait
    }
}

public enum SplitColumnWidth {
    /// The narrowest chat list (also the upstream minimum).
    public static let minimumMasterWidth: CGFloat = 320.0
    /// The narrowest chat beside it: about an iPad mini's chat pane.
    public static let minimumDetailWidth: CGFloat = 424.0
    /// The list never takes more than this share of the window.
    public static let maximumMasterFraction: CGFloat = 0.6
    /// An iPhone-wide list, one of the snap points.
    public static let phoneWidth: CGFloat = 375.0
    /// How close a drag has to come to a snap point to land on it.
    public static let snapDistance: CGFloat = 10.0
    /// One VoiceOver increment or decrement.
    public static let accessibilityStep: CGFloat = 40.0

    /// The upstream width: a third of the window, at least 320pt and at most half.
    public static func defaultMasterWidth(containerWidth: CGFloat) -> CGFloat {
        return min(max(minimumMasterWidth, floor(containerWidth / 3.0)), floor(containerWidth / 2.0))
    }

    /// The widths a user may choose, or nil when the window is too narrow for a choice (the list then has its
    /// default width).
    public static func range(containerWidth: CGFloat) -> ClosedRange<CGFloat>? {
        let upper = floor(min(containerWidth - minimumDetailWidth, containerWidth * maximumMasterFraction))
        if upper <= minimumMasterWidth {
            return nil
        }
        return minimumMasterWidth ... upper
    }

    private static func clamp(_ width: CGFloat, to range: ClosedRange<CGFloat>) -> CGFloat {
        return min(max(floor(width), range.lowerBound), range.upperBound)
    }

    /// The list width for a remembered preference: the preference clamped into today's range, or the default
    /// when there is none or no range. Clamping never changes the preference itself, so a window that shrinks
    /// (Stage Manager, Split View) and grows back gets the remembered width again.
    public static func masterWidth(containerWidth: CGFloat, preferred: CGFloat?) -> CGFloat {
        guard let preferred, let range = range(containerWidth: containerWidth) else {
            return defaultMasterWidth(containerWidth: containerWidth)
        }
        return clamp(preferred, to: range)
    }

    /// Narrow (320), phone width (375), the default third and half, as far as they are in range.
    public static func snapTargets(containerWidth: CGFloat) -> [CGFloat] {
        guard let range = range(containerWidth: containerWidth) else {
            return []
        }
        let candidates: [CGFloat] = [minimumMasterWidth, phoneWidth, defaultMasterWidth(containerWidth: containerWidth), floor(containerWidth / 2.0)]
        return Array(Set(candidates.filter { range.contains($0) })).sorted()
    }

    /// A width within `snapDistance` of a snap point lands on it; `target` is that point.
    public static func snapped(_ width: CGFloat, containerWidth: CGFloat) -> (width: CGFloat, target: CGFloat?) {
        var best: CGFloat?
        for target in snapTargets(containerWidth: containerWidth) {
            let distance = abs(target - width)
            if distance <= snapDistance, best.flatMap({ abs($0 - width) > distance }) ?? true {
                best = target
            }
        }
        if let best {
            return (best, best)
        }
        return (width, nil)
    }

    /// The width under the finger: the start width moved by the drag, kept in range, then snapped.
    public static func dragged(startWidth: CGFloat, translation: CGFloat, containerWidth: CGFloat) -> (width: CGFloat, target: CGFloat?) {
        guard let range = range(containerWidth: containerWidth) else {
            return (defaultMasterWidth(containerWidth: containerWidth), nil)
        }
        return snapped(clamp(startWidth + translation, to: range), containerWidth: containerWidth)
    }

    /// VoiceOver increment (`steps` > 0) or decrement (`steps` < 0), kept in range.
    public static func adjusted(current: CGFloat, steps: Int, containerWidth: CGFloat) -> CGFloat {
        guard let range = range(containerWidth: containerWidth) else {
            return defaultMasterWidth(containerWidth: containerWidth)
        }
        return clamp(current + CGFloat(steps) * accessibilityStep, to: range)
    }

    /// Whether the divider can be dragged. Only on a tablet (iPhone, including the Duo's fold split, keeps its
    /// fixed split), never while a vertical fold decides the split, and only when the window leaves a choice.
    public static func isResizable(isTablet: Bool, containerSize: CGSize, division: CGRect?) -> Bool {
        guard isTablet else {
            return false
        }
        if let division, division.width < containerSize.width, division.minY <= 0.5, division.maxY >= containerSize.height - 0.5 {
            return false
        }
        return range(containerWidth: containerSize.width) != nil
    }
}

/// The master width with an explicit preference (`splitMasterWidth(containerSize:division:)` passes the
/// remembered one). A vertical fold through the whole container (iPhone Duo) wins over any preference.
public func splitMasterWidth(containerSize: CGSize, division: CGRect?, preferredWidth: CGFloat?) -> CGFloat {
    if let division, division.width < containerSize.width, division.minY <= 0.5, division.maxY >= containerSize.height - 0.5 {
        return floorToScreenPixels(division.midX)
    }
    return SplitColumnWidth.masterWidth(containerWidth: containerSize.width, preferred: preferredWidth)
}

/// The remembered list width, in points, one per window shape, in UserDefaults under `nanogram.split.v1`.
/// Read once, synchronously; only a user action (drag, double-tap, VoiceOver) writes it. While a drag is in
/// progress its width is held in memory (`setLive`) and written once on release (`commit`).
/// Main thread only. One shared value is safe: the app has a single scene.
public final class SplitColumnWidthStore {
    public static let defaultsKey = "nanogram.split.v1"
    public static let shared = SplitColumnWidthStore(defaults: .standard)

    private let defaults: UserDefaults
    private var stored: [SplitColumnShape: CGFloat] = [:]
    private var live: [SplitColumnShape: CGFloat] = [:]

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        if let dictionary = defaults.dictionary(forKey: SplitColumnWidthStore.defaultsKey) {
            for shape in SplitColumnShape.allCases {
                if let value = dictionary[shape.rawValue] as? Double, value.isFinite, value > 0.0 {
                    self.stored[shape] = CGFloat(value)
                }
            }
        }
    }

    private func persist() {
        if self.stored.isEmpty {
            self.defaults.removeObject(forKey: SplitColumnWidthStore.defaultsKey)
        } else {
            var dictionary: [String: Double] = [:]
            for (shape, width) in self.stored {
                dictionary[shape.rawValue] = Double(width)
            }
            self.defaults.set(dictionary, forKey: SplitColumnWidthStore.defaultsKey)
        }
    }

    public func preferredWidth(for shape: SplitColumnShape) -> CGFloat? {
        return self.live[shape] ?? self.stored[shape]
    }

    public func preferredWidth(containerSize: CGSize) -> CGFloat? {
        return self.preferredWidth(for: SplitColumnShape(containerSize: containerSize))
    }

    /// The width of a drag in progress, if any.
    public func liveWidth(for shape: SplitColumnShape) -> CGFloat? {
        return self.live[shape]
    }

    public func setLive(_ width: CGFloat, for shape: SplitColumnShape) {
        self.live[shape] = width
    }

    public func cancelLive(for shape: SplitColumnShape) {
        self.live[shape] = nil
    }

    public func commit(_ width: CGFloat, for shape: SplitColumnShape) {
        self.live[shape] = nil
        self.stored[shape] = width
        self.persist()
    }

    public func reset(for shape: SplitColumnShape) {
        self.live[shape] = nil
        self.stored[shape] = nil
        self.persist()
    }
}

/// The live width of a drag, applied at most once per display frame. Pan events can outnumber the frames the
/// layout keeps up with (120 Hz on ProMotion), and each applied width lays out both columns: the chat list's
/// rows and the chat's bubbles are measured again. The divider records every width (`update`) and a 60 fps
/// display link takes the latest one (`takeChange`), so several events in a frame cost one layout, and a width
/// equal to the one on screen costs none.
public struct SplitColumnLiveDrag: Equatable {
    public private(set) var appliedWidth: CGFloat
    public private(set) var pendingWidth: CGFloat?

    public init(startWidth: CGFloat) {
        self.appliedWidth = startWidth
        self.pendingWidth = nil
    }

    public mutating func update(width: CGFloat) {
        self.pendingWidth = width
    }

    /// The width to lay out now, or nil when the screen already shows the latest one.
    public mutating func takeChange() -> CGFloat? {
        guard let pendingWidth = self.pendingWidth else {
            return nil
        }
        self.pendingWidth = nil
        if pendingWidth == self.appliedWidth {
            return nil
        }
        self.appliedWidth = pendingWidth
        return pendingWidth
    }
}
