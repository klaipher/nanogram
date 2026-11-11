import Foundation
import UIKit
import QuartzCore
import Darwin

/// CPU time a measured window cost: the main thread's (`thread_info`, read on the main thread) and the whole app's
/// (`getrusage`, every thread, the frame-hitch sampler included). On a fast phone a scroll rarely misses a frame whatever
/// the variant, so this is what tells two variants apart.
struct FrameHitchCPU: Equatable {
    struct Reading {
        let thread: Double
        let process: Double

        /// The calling thread's and the process's CPU time in seconds; nil when the kernel does not answer.
        static func current() -> Reading? {
            let thread = mach_thread_self()
            defer {
                mach_port_deallocate(mach_task_self_, thread)
            }
            var info = thread_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                    thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), reboundPointer, &count)
                }
            }
            guard result == KERN_SUCCESS else {
                return nil
            }
            var usage = rusage()
            guard getrusage(RUSAGE_SELF, &usage) == 0 else {
                return nil
            }
            let threadTime = seconds(info.user_time) + seconds(info.system_time)
            let processTime = seconds(usage.ru_utime) + seconds(usage.ru_stime)
            return Reading(thread: threadTime, process: processTime)
        }

        private static func seconds(_ value: time_value_t) -> Double {
            return Double(value.seconds) + Double(value.microseconds) / 1_000_000.0
        }

        private static func seconds(_ value: timeval) -> Double {
            return Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000.0
        }
    }

    let seconds: Double
    let mainThread: Double
    let app: Double

    init(seconds: Double, mainThread: Double, app: Double) {
        self.seconds = seconds
        self.mainThread = mainThread
        self.app = app
    }

    init(from start: Reading, to end: Reading, seconds: Double) {
        self.seconds = seconds
        self.mainThread = max(0.0, end.thread - start.thread)
        self.app = max(0.0, end.process - start.process)
    }
}

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
    /// A window that is still open after this long has lost its `end` (a list released mid-gesture, a cancelled
    /// touch): it is closed so its display link, run at the screen's top rate, does not tick for the rest of the
    /// session.
    static let maxWindowSeconds: Double = 60.0

    static func isExpired(startTime: Double, now: Double) -> Bool {
        return now - startTime >= FrameHitchStats.maxWindowSeconds
    }

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

    /// A window that opens while frames are being timed starts from the last frame seen, so a stall it opens in (a push
    /// that starts after the new screen was built in the same main-thread turn) is counted. A last frame older than
    /// `seedLimit` (the pause threshold: the link runs while the switch is on) is from before a pause and is not used.
    init(startTime: Double, lastFrame: Double?) {
        self.startTime = startTime
        if let lastFrame, startTime - lastFrame >= 0.0, startTime - lastFrame < FrameHitchStats.seedLimit {
            self.lastTimestamp = lastFrame
        }
    }

    static let seedLimit: Double = FrameHitchStats.pauseThreshold

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

    func summary(window: String, context: String?, cpu: FrameHitchCPU? = nil) -> String {
        let ratio = self.elapsed > 0.0 ? self.hitchTime * 1000.0 / self.elapsed : 0.0
        var line = String(format: "Frame hitches: window=%@ frames=%d seconds=%.2f hitches=%d hitchMs=%.1f msPerS=%.1f longestMs=%.1f", window, self.frames, self.elapsed, self.hitches, self.hitchTime * 1000.0, ratio, self.longestInterval * 1000.0)
        if let cpu, cpu.seconds > 0.0 {
            line += String(format: " mainCpuMs=%.1f mainCpuMsPerS=%.1f appCpuMsPerS=%.1f", cpu.mainThread * 1000.0, cpu.mainThread * 1000.0 / cpu.seconds, cpu.app * 1000.0 / cpu.seconds)
        }
        if let context {
            line += " ab=" + context
        }
        return line
    }
}

/// Debug Settings "Frame hitches: log with main-thread stacks" (off by default). While the switch is on, a display link
/// at the screen's top rate times every frame (so the screen stays at its top rate: a diagnostics mode), and a window
/// (a scroll of the chat, the chat list or any list, a keyboard animation, a push, pop or back swipe) counts the frames
/// it spans. At the window's end one summary line is logged, followed by the main thread's stacks during its longest
/// stalls, taken from a sampler the app starts while a window is open. Main thread only.
public final class FrameHitchMonitor {
    public static let shared = FrameHitchMonitor()

    public static var isEnabled: Bool = false {
        didSet {
            if !isEnabled {
                FrameHitchMonitor.shared.endAll()
            } else {
                // Timed for as long as the switch is on, so a window that opens mid-stall still sees the stall.
                FrameHitchMonitor.shared.startIfNeeded()
            }
            // The sampler runs for as long as the switch is on, so a stall that begins before a window opens (the tap
            // that raises the keyboard) still has its samples.
            if isEnabled != oldValue {
                FrameHitchMonitor.sampler?(isEnabled)
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
    /// Extra state appended to keyboard windows' summaries as ` kb=…` (where the system keyboard is drawn). Set by
    /// the app; runs on the main thread when a keyboard window ends.
    public static var keyboardState: (() -> String)?

    /// One stack per window: every stack is a few KB of log text, and a long window with 4 of them, repeated on each
    /// back swipe, added to the daily log volume.
    static let keptStallLimit = 1

    /// Stacks are logged only while the Frame hitches switch is on (a window the switch's turn-off closes logs its
    /// summary, but no stack).
    static func shouldLogStacks(isEnabled: Bool) -> Bool {
        return isEnabled
    }

    /// What the monitor holds, for the memory log: open windows, kept stack captures with their bytes, whether the
    /// display link runs, how many stack reports were queued and not yet built. Readable from any thread.
    public struct Diagnostics: Equatable {
        public var openSessions: Int = 0
        public var storedCaptures: Int = 0
        public var storedCaptureBytes: Int = 0
        public var isLinkRunning: Bool = false
        public var pendingReports: Int = 0
        public var expiredSessions: Int = 0

        public init() {
        }
    }

    private static let diagnosticsLock = NSLock()
    private static var diagnosticsValue = Diagnostics()

    public static var diagnostics: Diagnostics {
        FrameHitchMonitor.diagnosticsLock.lock()
        defer {
            FrameHitchMonitor.diagnosticsLock.unlock()
        }
        return FrameHitchMonitor.diagnosticsValue
    }

    private static func updateDiagnostics(_ f: (inout Diagnostics) -> Void) {
        FrameHitchMonitor.diagnosticsLock.lock()
        f(&FrameHitchMonitor.diagnosticsValue)
        FrameHitchMonitor.diagnosticsLock.unlock()
    }

    private func publishDiagnostics() {
        var captures = 0
        var bytes = 0
        for session in self.sessions.values {
            captures += session.captures.count
            for capture in session.captures.values {
                bytes += (capture as? NSData)?.length ?? 0
            }
        }
        let openSessions = self.sessions.count
        let isLinkRunning = self.link != nil
        FrameHitchMonitor.updateDiagnostics { value in
            value.openSessions = openSessions
            value.storedCaptures = captures
            value.storedCaptureBytes = bytes
            value.isLinkRunning = isLinkRunning
        }
    }

    /// Runs `body` on the report queue, counting it as pending until it has run.
    private static func enqueueReport(_ body: @escaping () -> Void) {
        FrameHitchMonitor.updateDiagnostics { $0.pendingReports += 1 }
        FrameHitchMonitor.reportQueue.async {
            body()
            FrameHitchMonitor.updateDiagnostics { $0.pendingReports -= 1 }
        }
    }
    /// Stack reports are built here, not on the main thread: building one walks a 128-frame tree with `dladdr`, which
    /// on the main thread was itself a stall the next window recorded.
    private static let reportQueue = DispatchQueue(label: "org.telegram.FrameHitchMonitor.report", qos: .utility)

    private final class Session {
        let name: String
        var stats: FrameHitchStats
        var captures: [Double: AnyObject] = [:]
        var deadline: Double?
        let startCPU: FrameHitchCPU.Reading?

        init(name: String, startTime: Double, lastFrame: Double?) {
            self.name = name
            self.stats = FrameHitchStats(startTime: startTime, lastFrame: lastFrame)
            self.startCPU = FrameHitchCPU.Reading.current()
        }
    }

    private var sessions: [String: Session] = [:]
    private var link: CADisplayLink?
    /// The last display-link callback; the link runs for as long as the switch is on, so a window can start from it.
    private var lastTickTimestamp: Double?
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
        self.sessions[name] = Session(name: name, startTime: CACurrentMediaTime(), lastFrame: self.lastTickTimestamp)
        self.startIfNeeded()
        self.publishDiagnostics()
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
        self.publishDiagnostics()
    }

    /// Times synchronous work that runs inside one frame (a display link cannot see a stall that starts before its
    /// window opens). Logs one line, and the main-thread stack, when it took at least `FrameHitchStats.stackThreshold`.
    @discardableResult
    public func measure<T>(_ name: String, alwaysLog: Bool = false, _ body: () -> T) -> T {
        guard FrameHitchMonitor.isEnabled else {
            return body()
        }
        let start = CACurrentMediaTime()
        let result = body()
        let end = CACurrentMediaTime()
        if alwaysLog || end - start >= FrameHitchStats.stackThreshold {
            var line = String(format: "Frame hitches: window=%@ syncMs=%.1f", name, (end - start) * 1000.0)
            if let context = FrameHitchMonitor.context?() {
                line += " ab=" + context
            }
            FrameHitchMonitor.log?(line)
            if let capture = FrameHitchMonitor.capture?(start, end), let report = FrameHitchMonitor.report, let log = FrameHitchMonitor.log {
                let header = String(format: "Frame hitch stack: window=%@ gapMs=%.1f atSeconds=0.00", name, (end - start) * 1000.0)
                FrameHitchMonitor.enqueueReport {
                    log(header + "\n" + report(capture))
                }
            }
        }
        return result
    }

    private func endAll() {
        let sessions = self.sessions.values
        self.sessions.removeAll()
        for session in sessions {
            self.finish(session)
        }
        self.stopIfIdle()
        self.publishDiagnostics()
    }

    fileprivate func startIfNeeded() {
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
    }

    private func stopIfIdle() {
        guard self.sessions.isEmpty, !FrameHitchMonitor.isEnabled, let link = self.link else {
            return
        }
        link.invalidate()
        self.link = nil
    }

    private func tick(_ link: CADisplayLink) {
        let timestamp = link.timestamp
        self.lastTickTimestamp = timestamp
        let expected = self.lastExpectedDuration ?? link.duration
        self.lastExpectedDuration = link.targetTimestamp - link.timestamp
        var expired: [String] = []
        var captureChanged = false
        for (name, session) in self.sessions {
            if let stall = session.stats.record(timestamp: timestamp, expectedDuration: expected) {
                if session.stats.keep(stall, limit: FrameHitchMonitor.keptStallLimit), let capture = FrameHitchMonitor.capture?(stall.start, stall.end) {
                    session.captures[stall.start] = capture
                    let kept = Set(session.stats.keptStalls.map(\.start))
                    session.captures = session.captures.filter { kept.contains($0.key) }
                    captureChanged = true
                }
            }
            if let deadline = session.deadline, timestamp >= deadline {
                expired.append(name)
            } else if FrameHitchStats.isExpired(startTime: session.stats.startTime, now: CACurrentMediaTime()) {
                expired.append(name)
                FrameHitchMonitor.updateDiagnostics { $0.expiredSessions += 1 }
            }
        }
        for name in expired {
            self.end(name)
        }
        if captureChanged {
            self.publishDiagnostics()
        }
    }

    private func finish(_ session: Session) {
        guard session.stats.frames > 0 else {
            return
        }
        var cpu: FrameHitchCPU?
        if let startCPU = session.startCPU, let endCPU = FrameHitchCPU.Reading.current() {
            cpu = FrameHitchCPU(from: startCPU, to: endCPU, seconds: CACurrentMediaTime() - session.stats.startTime)
        }
        var summary = session.stats.summary(window: session.name, context: FrameHitchMonitor.context?(), cpu: cpu)
        if session.name.hasPrefix("keyboard"), let keyboardState = FrameHitchMonitor.keyboardState?() {
            summary += " kb=" + keyboardState
        }
        FrameHitchMonitor.log?(summary)
        guard FrameHitchMonitor.shouldLogStacks(isEnabled: FrameHitchMonitor.isEnabled), let report = FrameHitchMonitor.report, let log = FrameHitchMonitor.log else {
            return
        }
        var pending: [(String, AnyObject)] = []
        for stall in session.stats.keptStalls {
            guard let capture = session.captures[stall.start] else {
                continue
            }
            let header = String(format: "Frame hitch stack: window=%@ gapMs=%.1f atSeconds=%.2f", session.name, (stall.end - stall.start) * 1000.0, stall.start - session.stats.startTime)
            pending.append((header, capture))
        }
        guard !pending.isEmpty else {
            return
        }
        FrameHitchMonitor.enqueueReport {
            for (header, capture) in pending {
                log(header + "\n" + report(capture))
            }
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
