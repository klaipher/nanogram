import Foundation

/// Debug Settings > Performance > "Back swipe: prepare the previous screen". Written by `SharedAccountContext`.
public enum NavigationPopPreparationSettings {
    public static var isEnabled: Bool = false
}

/// What the navigation container has already done for the swipe back that may begin: the screen beneath the top one,
/// laid out for a layout, and its display started, while the top screen is idle. `interactivePopBegan` then only
/// inserts a prepared node (a node that left the hierarchy has its contents cleared, so without this the swipe's start
/// lays it out and draws it, and waits for the drawing, on the main thread).
///
/// Generic over the layout so the rules are testable without a container; the container uses `ContainerViewLayout`.
struct NavigationPopPreparation<Layout: Equatable> {
    /// How long the top screen stays idle (no transition, no swipe) before the screen beneath is prepared: past a
    /// push's landing and the first things a new screen does.
    static var idleDelay: TimeInterval { return 0.6 }

    private(set) var prepared: (controller: ObjectIdentifier, layout: Layout)?

    /// Whether a preparation is worth scheduling now.
    static func canPrepare(isEnabled: Bool, isInFocus: Bool, hasTransition: Bool, hasInteractivePop: Bool, hasPendingChild: Bool, controllerCount: Int) -> Bool {
        return isEnabled && isInFocus && !hasTransition && !hasInteractivePop && !hasPendingChild && controllerCount > 1
    }

    /// The prepared screen is this one, laid out for this layout: nothing is left to do for it.
    func isPrepared(controller: ObjectIdentifier, layout: Layout) -> Bool {
        guard let prepared = self.prepared else {
            return false
        }
        return prepared.controller == controller && prepared.layout == layout
    }

    mutating func markPrepared(controller: ObjectIdentifier, layout: Layout) {
        self.prepared = (controller, layout)
    }

    /// The swipe takes the prepared screen (or something invalidated it). Returns the screen that was prepared.
    @discardableResult
    mutating func reset() -> ObjectIdentifier? {
        let controller = self.prepared?.controller
        self.prepared = nil
        return controller
    }
}
