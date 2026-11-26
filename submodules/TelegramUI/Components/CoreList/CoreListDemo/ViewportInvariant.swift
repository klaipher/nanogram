import Foundation
import CoreGraphics

// Always-on, read-only diagnostics for "the list shows a big empty area" (chat history: one bubble cut at the top, wallpaper
// below). Everything here is pure: numbers in, a verdict or a line of numbers out. No message text, no peer ids.
//
// Why it does not filter designed slack out: the two leading causes (the bottom-edge pin's slack and the scroll hold's slack)
// are DECLARED scroll room, so the gap they leave equals the declared slack and a "gap beyond slack" test would never fire.
// It reports a large newest-edge gap together with the term that backs it, which separates pin / hold / stack slack from an
// offset that left the declared edges.

/// What the list looked like at one settled moment, read from the engine and the loaded window.
struct CoreListViewportSnapshot: Equatable {
    var itemCount: Int
    var windowIsEmpty: Bool
    var windowStartIndex: Int
    var windowEndIndex: Int
    /// Height between the top and bottom insets.
    var visibleHeight: CGFloat
    /// Height of the loaded window (rows plus reserved attachment bands).
    var windowHeight: CGFloat
    /// Blank height between the top inset edge and the newest loaded row, positive when the row starts below the edge.
    /// With the window at index 0 it is edge room (pin, hold or stack slack); with it short of index 0 it is a part of
    /// the visible band that newer rows should cover and do not.
    var newestEdgeGap: CGFloat
    /// The mirror at the oldest end: blank below the oldest loaded row.
    var oldestEdgeGap: CGFloat
    var offset: CGFloat
    var declaredMinEdge: CGFloat?
    var declaredMaxEdge: CGFloat?
    var bottomEdgePinSlack: CGFloat
    var holdSlackMin: CGFloat
    var holdSlackMax: CGFloat
    var stackFromBottomSlack: CGFloat
    var hasHeldRow: Bool
    var lowestPinnedItemIndex: Int?
    /// Whether any loaded row's frame intersects the visible band.
    var anyRowIntersectsBand: Bool
    /// Loaded rows inside the band whose view is hidden or fully transparent.
    var hiddenRowsInBand: Int
    var hasActiveFlight: Bool
    var isTrackingTouch: Bool
    var rebalanceDeferredRows: Bool
    var windowRevision: Int
}

enum CoreListBlankBacking: String, Equatable {
    case pinSlack
    case holdSlack
    case stackSlack
    /// Nothing declared backs the gap: the offset left the declared edges, or the window sits away from them.
    case none
}

enum CoreListViewportEdge: String, Equatable {
    case newest
    case oldest
}

enum CoreListInvariantFinding: Equatable {
    case noRowInBand
    /// The window stops short of that end of the collection, yet the visible band reaches past its loaded rows: rows that
    /// exist are not loaded where they would be seen (a window rebalanced for an older offset, or one that fell behind).
    case unloadedGap(edge: CoreListViewportEdge, gap: CGFloat)
    case newestEdgeGap(gap: CGFloat, backing: CoreListBlankBacking)
    case oldestEdgeGap(gap: CGFloat, backing: CoreListBlankBacking)
    case offsetOutsideDeclaredEdges(by: CGFloat)
    case hiddenRowInBand(count: Int)

    var name: String {
        switch self {
        case .noRowInBand: return "noRowInBand"
        case .unloadedGap: return "unloadedGap"
        case .newestEdgeGap: return "newestEdgeGap"
        case .oldestEdgeGap: return "oldestEdgeGap"
        case .offsetOutsideDeclaredEdges: return "offsetOutsideEdges"
        case .hiddenRowInBand: return "hiddenRowInBand"
        }
    }
}

enum CoreListViewportInvariant {
    /// A gap smaller than this share of the visible area is ordinary (a short chat, a row's own spacing).
    static let gapShareOfVisibleArea: CGFloat = 0.25
    static let edgeTolerance: CGFloat = 0.5

    /// Findings for a list that is AT REST: no flight, no finger. Empty while it is moving or empty of items.
    static func evaluate(_ s: CoreListViewportSnapshot) -> [CoreListInvariantFinding] {
        guard s.itemCount > 0, !s.windowIsEmpty, !s.hasActiveFlight, !s.isTrackingTouch, s.visibleHeight > 0 else { return [] }
        var findings: [CoreListInvariantFinding] = []
        let threshold = s.visibleHeight * gapShareOfVisibleArea

        if !s.anyRowIntersectsBand {
            findings.append(.noRowInBand)
        }
        if s.newestEdgeGap > threshold {
            if s.windowStartIndex == 0 {
                findings.append(.newestEdgeGap(gap: s.newestEdgeGap, backing: newestBacking(s)))
            } else {
                findings.append(.unloadedGap(edge: .newest, gap: s.newestEdgeGap))
            }
        }
        if s.oldestEdgeGap > threshold {
            if s.windowEndIndex != s.itemCount - 1 {
                findings.append(.unloadedGap(edge: .oldest, gap: s.oldestEdgeGap))
            } else if !(s.windowStartIndex == 0 && s.windowHeight < s.visibleHeight) {
                // A whole collection shorter than the visible area leaves this blank by its own geometry (a chat with a
                // few messages): not a finding. An offset that left the edges is reported below either way.
                findings.append(.oldestEdgeGap(gap: s.oldestEdgeGap, backing: oldestBacking(s)))
            }
        }
        var outside: CGFloat = 0
        if let minimum = s.declaredMinEdge, s.offset < minimum - edgeTolerance { outside = minimum - s.offset }
        if let maximum = s.declaredMaxEdge, s.offset > maximum + edgeTolerance { outside = max(outside, s.offset - maximum) }
        if outside > 0 {
            findings.append(.offsetOutsideDeclaredEdges(by: outside))
        }
        if s.hiddenRowsInBand > 0 {
            findings.append(.hiddenRowInBand(count: s.hiddenRowsInBand))
        }
        return findings
    }

    /// The largest declared term that can account for a newest-edge gap; `.none` when no term is positive.
    static func newestBacking(_ s: CoreListViewportSnapshot) -> CoreListBlankBacking {
        let pin = s.bottomEdgePinSlack
        let hold = s.holdSlackMin
        let stack = s.stackFromBottomSlack
        let largest = max(pin, hold, stack)
        guard largest > edgeTolerance else { return .none }
        if pin == largest { return .pinSlack }
        if hold == largest { return .holdSlack }
        return .stackSlack
    }

    static func oldestBacking(_ s: CoreListViewportSnapshot) -> CoreListBlankBacking {
        return s.holdSlackMax > edgeTolerance ? .holdSlack : .none
    }

    /// What kind of state the findings describe, without their magnitudes: a state that persists (a pin held through a
    /// whole streaming reply) is logged again only after a longer interval, not once a second.
    static func signature(_ findings: [CoreListInvariantFinding]) -> String {
        return findings.map { finding -> String in
            switch finding {
            case let .unloadedGap(edge, _):
                return "unloadedGap.\(edge.rawValue)"
            case let .newestEdgeGap(_, backing):
                return "newestEdgeGap.\(backing.rawValue)"
            case let .oldestEdgeGap(_, backing):
                return "oldestEdgeGap.\(backing.rawValue)"
            default:
                return finding.name
            }
        }.joined(separator: ",")
    }

    /// One line of numbers for the log.
    static func format(_ s: CoreListViewportSnapshot, findings: [CoreListInvariantFinding], trigger: String) -> String {
        func n(_ v: CGFloat) -> String { String(format: "%.1f", Double(v)) }
        func o(_ v: CGFloat?) -> String { v.map { n($0) } ?? "-" }
        var parts: [String] = ["trigger=\(trigger)"]
        for finding in findings {
            switch finding {
            case .noRowInBand:
                parts.append("noRowInBand")
            case let .unloadedGap(edge, gap):
                parts.append("unloadedGap=\(n(gap)) edge=\(edge.rawValue)")
            case let .newestEdgeGap(gap, backing):
                parts.append("newestGap=\(n(gap)) backing=\(backing.rawValue)")
            case let .oldestEdgeGap(gap, backing):
                parts.append("oldestGap=\(n(gap)) backing=\(backing.rawValue)")
            case let .offsetOutsideDeclaredEdges(by):
                parts.append("outsideEdgesBy=\(n(by))")
            case let .hiddenRowInBand(count):
                parts.append("hiddenRows=\(count)")
            }
        }
        parts.append("items=\(s.itemCount) window=\(s.windowStartIndex)...\(s.windowEndIndex) windowHeight=\(n(s.windowHeight)) visible=\(n(s.visibleHeight))")
        parts.append("offset=\(n(s.offset)) edges=\(o(s.declaredMinEdge))/\(o(s.declaredMaxEdge))")
        parts.append("pinSlack=\(n(s.bottomEdgePinSlack)) pinIndex=\(s.lowestPinnedItemIndex.map { String($0) } ?? "-") holdSlack=\(n(s.holdSlackMin))/\(n(s.holdSlackMax)) held=\(s.hasHeldRow) stackSlack=\(n(s.stackFromBottomSlack))")
        parts.append("deferredRows=\(s.rebalanceDeferredRows) rev=\(s.windowRevision)")
        return parts.joined(separator: " ")
    }
}

/// At most one line per interval, per key, so a state that persists does not flood the log.
struct CoreListDiagnosticRateLimiter {
    let interval: Double
    private var lastByKey: [String: Double] = [:]

    init(interval: Double = 1.0) {
        self.interval = interval
    }

    mutating func allow(key: String, now: Double) -> Bool {
        if let last = lastByKey[key], now - last < interval, now >= last {
            return false
        }
        lastByKey[key] = now
        return true
    }
}

/// Nanogram: which `diagnosticLog` lines a host may also send to an always-on, size-capped log, and the key it may
/// budget them by. The finding and event lines go; the dump of recent events (long, and only useful next to the full
/// log) does not.
public enum CoreListDiagnosticShortLog {
    /// The start of the recent-events line `checkViewportInvariant` writes after a finding.
    public static let recentEventsPrefix = "recent "
    public static let maxKeyLength = 120

    public static func belongsInShortLog(_ line: String) -> Bool {
        return !line.hasPrefix(recentEventsPrefix)
    }

    /// The kind of line, without its magnitudes: the part before the list-shape numbers (`items=`), with every number
    /// dropped. Two findings of the same kinds and backings share a key; a different finding or event does not.
    public static func budgetKey(_ line: String) -> String {
        var head = Substring(line)
        if let range = line.range(of: " items=") {
            head = line[line.startIndex ..< range.lowerBound]
        }
        let characters = Array(head)
        var key = ""
        for index in characters.indices {
            let character = characters[index]
            if character.isASCII && character.isNumber {
                continue
            }
            if character == "." || character == "-" {
                let nextIndex = index + 1
                if nextIndex < characters.count, characters[nextIndex].isASCII, characters[nextIndex].isNumber {
                    continue
                }
            }
            key.append(character)
            if key.count >= maxKeyLength {
                break
            }
        }
        return key
    }
}

/// A fixed-size record of the last events that moved the list. Numbers and enums only; formatted when a violation is
/// dumped, so recording is a struct write.
struct CoreListEventRing {
    enum Kind: String {
        case transaction
        case scrollTo
        case flightFinalize
        case deltaClamp
        case deferredApplyQueued
        case deferredApplyRan
        case settleCheck
    }

    struct Event: Equatable {
        var kind: Kind
        var time: Double
        var a: CGFloat
        var b: CGFloat
        var flags: UInt8
    }

    let capacity: Int
    private var storage: [Event] = []
    private var next = 0

    init(capacity: Int = 40) {
        self.capacity = max(1, capacity)
        self.storage.reserveCapacity(self.capacity)
    }

    var count: Int { storage.count }

    mutating func record(_ kind: Kind, time: Double, a: CGFloat = 0, b: CGFloat = 0, flags: UInt8 = 0) {
        let event = Event(kind: kind, time: time, a: a, b: b, flags: flags)
        if storage.count < capacity {
            storage.append(event)
        } else {
            storage[next] = event
        }
        next = (next + 1) % capacity
    }

    /// Oldest first.
    var events: [Event] {
        if storage.count < capacity { return storage }
        return Array(storage[next...] + storage[..<next])
    }

    func formatted(now: Double) -> String {
        return events.map { event in
            let age = String(format: "%.2f", now - event.time)
            return "\(event.kind.rawValue)@-\(age)s(\(String(format: "%.0f", Double(event.a))),\(String(format: "%.0f", Double(event.b))),f\(event.flags))"
        }.joined(separator: " ")
    }
}

/// Nanogram: the one repair the list makes by itself for a blank area. When the list has come to rest (no flight, no
/// deceleration, no finger) with its offset outside the declared edges, it springs back with the engine's own edge bounce,
/// as a tap on an overscrolled list does. The declared edges already include the pin, hold and stack slack and the
/// overscroll-action hold, so designed room is never taken away. A pass that lands during an edge bounce and halts the
/// motion (the settle clamp is skipped for an overscrolled pass) used to leave the list resting past the newest edge, blank
/// below the newest bubble, until the next touch. At most once per `minimumInterval`, so it cannot loop.
struct CoreListRestSpringBack {
    static let minimumInterval: CFTimeInterval = 1.0
    private var lastAt: CFTimeInterval?

    static func isNeeded(isFlying: Bool, isDecelerating: Bool, isTrackingTouch: Bool, isOverscrolled: Bool) -> Bool {
        return isOverscrolled && !isFlying && !isDecelerating && !isTrackingTouch
    }

    mutating func allow(now: CFTimeInterval) -> Bool {
        if let lastAt, now - lastAt < Self.minimumInterval {
            return false
        }
        self.lastAt = now
        return true
    }
}
