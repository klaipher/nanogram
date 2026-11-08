import Foundation
import UIKit
import QuartzCore

/// Frame timing of one measured window (a chat scroll, a keyboard animation). A frame is a hitch when the display
/// link fires more than half a frame later than the frame the system planned (`targetTimestamp - timestamp` of the
/// previous callback), so a ProMotion rate change is not a hitch. Stalls of at least three planned frames and 25 ms
/// are candidates for a main-thread stack; only the longest few are kept.
struct FrameHitchStats {
    struct Stall: Equatable {
        let start: Double
        let end: Double
    }

    /// A gap longer than this is the link pausing (app in the background, link stopped), not a frame.
    static let pauseThreshold: Double = 1.0
    static let stackThreshold: Double = 0.025

    let startTime: Double
    private(set) var frames: Int = 0
    private(set) var hitches: Int = 0
    private(set) var hitchTime: Double = 0.0
    private(set) var elapsed: Double = 0.0
    private(set) var longestInterval: Double = 0.0
    private(set) var keptStalls: [Stall] = []
    private var lastTimestamp: Double?

    init(startTime: Double) {
        self.startTime = startTime
    }

    /// Records one display-link callback. Returns the stall when this frame is long enough to deserve a stack.
    @discardableResult
    mutating func record(timestamp: Double, expectedDuration: Double) -> Stall? {
        defer {
            self.lastTimestamp = timestamp
        }
        guard let lastTimestamp = self.lastTimestamp else {
            return nil
        }
        let interval = timestamp - lastTimestamp
        guard interval > 0.0, interval < FrameHitchStats.pauseThreshold else {
            return nil
        }
        self.frames += 1
        self.elapsed += interval
        self.longestInterval = max(self.longestInterval, interval)
        guard expectedDuration > 0.0, interval > expectedDuration * 1.5 else {
            return nil
        }
        self.hitches += 1
        self.hitchTime += interval - expectedDuration
        if interval >= max(FrameHitchStats.stackThreshold, expectedDuration * 3.0) {
            return Stall(start: lastTimestamp, end: timestamp)
        }
        return nil
    }

    /// Keeps `stall` if it is among the `limit` longest so far. Returns whether it was kept.
    @discardableResult
    mutating func keep(_ stall: Stall, limit: Int) -> Bool {
        self.keptStalls.append(stall)
        self.keptStalls.sort { ($0.end - $0.start) > ($1.end - $1.start) }
        if self.keptStalls.count > limit {
            self.keptStalls.removeLast(self.keptStalls.count - limit)
        }
        return self.keptStalls.contains(stall)
    }

    func summary(window: String, context: String?) -> String {
        let ratio = self.elapsed > 0.0 ? self.hitchTime * 1000.0 / self.elapsed : 0.0
        var line = String(format: "Frame hitches: window=%@ frames=%d seconds=%.2f hitches=%d hitchMs=%.1f msPerS=%.1f longestMs=%.1f", window, self.frames, self.elapsed, self.hitches, self.hitchTime * 1000.0, ratio, self.longestInterval * 1000.0)
        if let context {
            line += " ab=" + context
        }
        return line
    }
}

/// Debug Settings "Frame hitches: log with main-thread stacks" (off by default). While a window is open (a scroll of
/// the chat, the chat list or any list, a keyboard animation), a display link at the screen's top rate times every
/// frame. At the window's end one summary line is logged, followed by the main thread's stacks during its longest
/// stalls, taken from a sampler the app starts while a window is open. Main thread only.
public final class FrameHitchMonitor {
    public static let shared = FrameHitchMonitor()

    public static var isEnabled: Bool = false {
        didSet {
            if !isEnabled {
                FrameHitchMonitor.shared.endAll()
            }
        }
    }
    public static var log: ((String) -> Void)?
    /// The A/B switch state, appended to each summary as ` ab=…`.
    public static var context: (() -> String)?
    /// Starts (true) or stops (false) the app's main-thread sampler.
    public static var sampler: ((Bool) -> Void)?
    /// Copies the sampler's samples between two `CACurrentMediaTime()` instants (cheap; runs right after a stall).
    public static var capture: ((Double, Double) -> AnyObject?)?
    /// Turns a capture into a text call tree (runs when the window ends).
    public static var report: ((AnyObject) -> String)?

    static let keptStallLimit = 4

    private final class Session {
        let name: String
        var stats: FrameHitchStats
        var captures: [Double: AnyObject] = [:]
        var deadline: Double?

        init(name: String, startTime: Double) {
            self.name = name
            self.stats = FrameHitchStats(startTime: startTime)
        }
    }

    private var sessions: [String: Session] = [:]
    private var link: CADisplayLink?
    private var lastExpectedDuration: Double?

    private init() {
    }

    /// Opens `name` (or keeps it open with no end time if it is already open).
    public func begin(_ name: String) {
        guard FrameHitchMonitor.isEnabled else {
            return
        }
        if let session = self.sessions[name] {
            session.deadline = nil
            return
        }
        self.sessions[name] = Session(name: name, startTime: CACurrentMediaTime())
        self.startIfNeeded()
    }

    /// Opens `name` until `duration` seconds from now (a keyboard animation).
    public func observe(_ name: String, duration: Double) {
        guard FrameHitchMonitor.isEnabled else {
            return
        }
        self.begin(name)
        self.sessions[name]?.deadline = CACurrentMediaTime() + duration
    }

    public func end(_ name: String) {
        guard let session = self.sessions.removeValue(forKey: name) else {
            return
        }
        self.finish(session)
        self.stopIfIdle()
    }

    private func endAll() {
        let sessions = self.sessions.values
        self.sessions.removeAll()
        for session in sessions {
            self.finish(session)
        }
        self.stopIfIdle()
    }

    private func startIfNeeded() {
        guard self.link == nil else {
            return
        }
        let link = CADisplayLink(target: FrameHitchLinkTarget({ [weak self] link in
            self?.tick(link)
        }), selector: #selector(FrameHitchLinkTarget.event(_:)))
        if #available(iOS 15.0, *) {
            let maxRate = Float(UIScreen.main.maximumFramesPerSecond)
            link.preferredFrameRateRange = CAFrameRateRange(minimum: maxRate, maximum: maxRate, preferred: maxRate)
        }
        link.add(to: .main, forMode: .common)
        self.link = link
        self.lastExpectedDuration = nil
        FrameHitchMonitor.sampler?(true)
    }

    private func stopIfIdle() {
        guard self.sessions.isEmpty, let link = self.link else {
            return
        }
        link.invalidate()
        self.link = nil
        FrameHitchMonitor.sampler?(false)
    }

    private func tick(_ link: CADisplayLink) {
        let timestamp = link.timestamp
        let expected = self.lastExpectedDuration ?? link.duration
        self.lastExpectedDuration = link.targetTimestamp - link.timestamp
        var expired: [String] = []
        for (name, session) in self.sessions {
            if let stall = session.stats.record(timestamp: timestamp, expectedDuration: expected) {
                if session.stats.keep(stall, limit: FrameHitchMonitor.keptStallLimit), let capture = FrameHitchMonitor.capture?(stall.start, stall.end) {
                    session.captures[stall.start] = capture
                    let kept = Set(session.stats.keptStalls.map(\.start))
                    session.captures = session.captures.filter { kept.contains($0.key) }
                }
            }
            if let deadline = session.deadline, timestamp >= deadline {
                expired.append(name)
            }
        }
        for name in expired {
            self.end(name)
        }
    }

    private func finish(_ session: Session) {
        guard session.stats.frames > 0 else {
            return
        }
        FrameHitchMonitor.log?(session.stats.summary(window: session.name, context: FrameHitchMonitor.context?()))
        guard let report = FrameHitchMonitor.report else {
            return
        }
        for stall in session.stats.keptStalls {
            guard let capture = session.captures[stall.start] else {
                continue
            }
            let header = String(format: "Frame hitch stack: window=%@ gapMs=%.1f atSeconds=%.2f", session.name, (stall.end - stall.start) * 1000.0, stall.start - session.stats.startTime)
            FrameHitchMonitor.log?(header + "\n" + report(capture))
        }
    }
}

private final class FrameHitchLinkTarget: NSObject {
    private let action: (CADisplayLink) -> Void

    init(_ action: @escaping (CADisplayLink) -> Void) {
        self.action = action
    }

    @objc func event(_ link: CADisplayLink) {
        self.action(link)
    }
}
