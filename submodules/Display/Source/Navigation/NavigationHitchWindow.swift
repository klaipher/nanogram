import Foundation

/// The frame-hitch window of the navigation transition running now (Debug Settings "Frame hitches"). At most one is open:
/// opening another closes the first, and every ending of a transition (landing, committed swipe, cancelled swipe) closes it.
/// Pure so the lifecycle is testable without a container.
struct NavigationHitchWindow: Equatable {
    private(set) var name: String?

    /// Opens `name`. Returns the window that was open and has to be closed now.
    mutating func begin(_ name: String) -> String? {
        let previous = self.name
        self.name = name
        return previous
    }

    /// Closes the open window. Returns its name, nil when none is open.
    mutating func end() -> String? {
        let name = self.name
        self.name = nil
        return name
    }

    var isOpen: Bool {
        return self.name != nil
    }
}
