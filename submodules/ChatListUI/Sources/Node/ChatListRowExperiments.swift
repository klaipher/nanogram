import Foundation

/// Debug Settings ▸ LIST SCROLL (A/B VS TELEGRAM). Written by SharedAccountContextImpl on the main thread at launch and
/// on change; read when a row node is created (any queue — a stale read only puts one row in the former mode).
public enum ChatListRowExperiments {
    /// "Chat list rows: lazy rare subnodes" (default on).
    public static var lazyRareSubnodes: Bool = true
    /// "Chat list rows: reuse rows" (default off). Part 2.
    public static var rowReuse: Bool = false
}
