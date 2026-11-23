import XCTest
@testable import TelegramCore

/// A discrete-event model of one shared FIFO uplink, driving the real `UploadPartWindow`.
/// Worst case on purpose: any single attempt that lasts 12 s or more counts as a connection reset (all parts in
/// flight are lost and retried with the back-off of `PendingUploadPartRetryPolicy`).
private struct SimulatedUplink {
    struct Result {
        var finishTime: Double
        var finished: Bool
        var resets: Int
        var stats: UploadPartWindow.Stats
        var finalWindow: Int
        var windowTrace: [(at: Double, window: Int)]
        /// Finishes of a part that had been retried after which the window was larger than before (must be 0).
        var retriedCredits: Int = 0
    }

    private struct Rng {
        var state: UInt64
        mutating func next() -> Double {
            self.state = self.state &* 6364136223846793005 &+ 1442695040888963407
            return Double((self.state >> 33) & 0xFFFFFF) / Double(0x1000000)
        }
    }

    private struct Attempt {
        var bytes: Int
        var attemptStart: Double
        var eventAt: Double
        var isReset: Bool
        var retries: Int
    }

    /// (until, bytes per second); the last segment ends at infinity.
    var schedule: [(until: Double, rate: Double)]
    var rtt: Double
    var loss = 0.0
    var seed: UInt64 = 42
    var lossDetect = 12.0
    var maxTime = 600.0
    private let backoff: [Double] = [0.5, 1.0, 2.0, 4.0]

    init(bandwidth: Double, rtt: Double, loss: Double = 0.0) {
        self.schedule = [(until: Double.infinity, rate: bandwidth)]
        self.rtt = rtt
        self.loss = loss
    }

    init(schedule: [(until: Double, rate: Double)], rtt: Double) {
        self.schedule = schedule
        self.rtt = rtt
    }

    private func transmitEnd(from start: Double, bytes: Double) -> Double {
        var time = start
        var remaining = bytes
        for segment in self.schedule {
            if time >= segment.until {
                continue
            }
            let capacity = (segment.until - time) * segment.rate
            if remaining <= capacity {
                return time + remaining / segment.rate
            }
            remaining -= capacity
            time = segment.until
        }
        return time
    }

    /// `fixedWindow` set: a plain fixed-size window (the old behaviour) for comparison.
    func run(fileSize: Int, partSize: Int, network: UploadPartWindow.NetworkClass, fixedWindow: Int? = nil) -> Result {
        var window = UploadPartWindow(UploadPartWindow.Config(partSize: partSize, network: network))
        var rng = Rng(state: self.seed)
        var now = 0.0
        var linkFree = 0.0
        var resets = 0
        var retriedCredits = 0
        var done = 0
        var nextPart = 0
        var inFlight: [Int64: Attempt] = [:]
        var trace: [(at: Double, window: Int)] = [(at: 0, window: window.window)]
        let totalParts = (fileSize + partSize - 1) / partSize

        func schedule(_ bytes: Int, resumeAt: Double, retries: Int, rng: inout Rng, linkFree: inout Double) -> Attempt {
            let start = max(resumeAt, linkFree)
            let end = self.transmitEnd(from: start, bytes: Double(bytes))
            linkFree = end
            let finish = end + self.rtt
            let lost = self.loss > 0 && rng.next() < self.loss
            if lost || finish - resumeAt >= self.lossDetect {
                return Attempt(bytes: bytes, attemptStart: resumeAt, eventAt: resumeAt + self.lossDetect, isReset: true, retries: retries)
            }
            return Attempt(bytes: bytes, attemptStart: resumeAt, eventAt: finish, isReset: false, retries: retries)
        }

        while done < totalParts && now < self.maxTime {
            let allowed = fixedWindow ?? window.allowedInFlight
            while inFlight.count < allowed && nextPart < totalParts {
                let bytes = min(partSize, fileSize - nextPart * partSize)
                let id = Int64(nextPart)
                window.partStarted(id: id, bytes: bytes, inFlight: inFlight.count, at: now)
                inFlight[id] = schedule(bytes, resumeAt: now, retries: 0, rng: &rng, linkFree: &linkFree)
                nextPart += 1
            }
            guard let next = inFlight.min(by: { ($0.value.eventAt, $0.key) < ($1.value.eventAt, $1.key) }) else {
                break
            }
            now = max(now, next.value.eventAt)
            if next.value.isReset {
                resets += 1
                linkFree = now
                for id in inFlight.keys.sorted() {
                    guard var attempt = inFlight[id] else {
                        continue
                    }
                    let delay = self.backoff[min(attempt.retries, self.backoff.count - 1)]
                    window.partRetried(id: id, at: now, resumesAt: now + delay)
                    attempt = schedule(attempt.bytes, resumeAt: now + delay, retries: attempt.retries + 1, rng: &rng, linkFree: &linkFree)
                    inFlight[id] = attempt
                }
            } else {
                inFlight.removeValue(forKey: next.key)
                done += 1
                let before = window.window
                window.partFinished(id: next.key, at: now)
                if next.value.retries > 0 && window.window > before {
                    retriedCredits += 1
                }
            }
            if trace.last?.window != window.window {
                trace.append((at: now, window: window.window))
            }
        }
        let finished = done == totalParts
        return Result(finishTime: finished ? now : Double.infinity, finished: finished, resets: resets, stats: window.stats, finalWindow: window.window, windowTrace: trace, retriedCredits: retriedCredits)
    }
}

final class UploadPartWindowTests: XCTestCase {
    private let kb = 1024
    private let mb = 1024 * 1024

    // MARK: Helpers for direct event tests

    /// Starts `count` parts with `inFlight` filled, then finishes each `duration` s later, one every `spacing` s.
    private func feed(_ window: inout UploadPartWindow, count: Int, from first: Int64 = 0, bytes: Int, duration: Double, spacing: Double, startAt: Double = 0, inFlight: Int? = nil) -> Double {
        var time = startAt
        for index in 0 ..< count {
            let id = first + Int64(index)
            window.partStarted(id: id, bytes: bytes, inFlight: inFlight ?? max(0, window.allowedInFlight - 1), at: time)
            window.partFinished(id: id, at: time + duration)
            time += spacing
        }
        return time
    }

    // MARK: Simulator scenarios

    func testT1FastWifiSmallParts() {
        let link = SimulatedUplink(bandwidth: 2.0 * Double(mb), rtt: 0.2)
        let adaptive = link.run(fileSize: 4 * mb, partSize: 128 * kb, network: .wifi)
        let fixed = link.run(fileSize: 4 * mb, partSize: 128 * kb, network: .wifi, fixedWindow: 6)
        XCTAssertGreaterThanOrEqual(adaptive.stats.minWindow, 6)
        XCTAssertEqual(adaptive.stats.maxWindow, 8)
        XCTAssertEqual(adaptive.stats.decreases, 0)
        XCTAssertTrue(adaptive.finished)
        XCTAssertLessThanOrEqual(adaptive.finishTime, fixed.finishTime)
    }

    func testT2FastWifiBigParts() {
        let link = SimulatedUplink(bandwidth: 4.0 * Double(mb), rtt: 0.1)
        let result = link.run(fileSize: 20 * mb, partSize: 512 * kb, network: .wifi)
        XCTAssertEqual(result.stats.maxWindow, 3)
        XCTAssertEqual(result.stats.minWindow, 3)
        XCTAssertTrue(result.windowTrace.allSatisfy { $0.window == 3 })
    }

    func testT3HighLatencyWifi() {
        let link = SimulatedUplink(bandwidth: Double(mb), rtt: 0.4)
        let adaptive = link.run(fileSize: 4 * mb, partSize: 128 * kb, network: .wifi)
        let fixed = link.run(fileSize: 4 * mb, partSize: 128 * kb, network: .wifi, fixedWindow: 6)
        XCTAssertGreaterThanOrEqual(adaptive.stats.minWindow, 6)
        XCTAssertEqual(adaptive.stats.maxWindow, 8)
        XCTAssertLessThanOrEqual(adaptive.finishTime, fixed.finishTime)
    }

    func testT4SlowCellular() {
        let link = SimulatedUplink(bandwidth: 60.0 * Double(kb), rtt: 0.15)
        let adaptive = link.run(fileSize: 2 * mb, partSize: 128 * kb, network: .cellular)
        let fixed6 = link.run(fileSize: 2 * mb, partSize: 128 * kb, network: .cellular, fixedWindow: 6)
        let fixed4 = link.run(fileSize: 2 * mb, partSize: 128 * kb, network: .cellular, fixedWindow: 4)
        XCTAssertEqual(UploadPartWindow(UploadPartWindow.Config(partSize: 128 * kb, network: .cellular)).window, 4, "the cellular start")
        XCTAssertEqual(adaptive.resets, 0)
        XCTAssertGreaterThanOrEqual(fixed6.resets, 1, "a 6th part takes 12.8 s on this link")
        XCTAssertEqual(adaptive.finalWindow, 2)
        XCTAssertGreaterThanOrEqual(adaptive.stats.minWindow, 2)
        XCTAssertTrue(adaptive.finished)
        XCTAssertLessThanOrEqual(adaptive.finishTime, fixed4.finishTime * 1.05)
    }

    func testT5Recovery() {
        let link = SimulatedUplink(schedule: [(until: 20.0, rate: 60.0 * Double(kb)), (until: Double.infinity, rate: 1.5 * Double(mb))], rtt: 0.15)
        let result = link.run(fileSize: 16 * mb, partSize: 128 * kb, network: .cellular)
        XCTAssertTrue(result.finished)
        XCTAssertEqual(result.windowTrace.first(where: { $0.at > 0 })?.window, 2, "the slow phase drops the window to 2")
        XCTAssertGreaterThanOrEqual(result.finalWindow, 6)
        XCTAssertTrue(result.windowTrace.filter { $0.at > 25 }.allSatisfy { $0.window >= 2 })
        // No decrease after t = 25 s: the window never goes down again, so the trace after then is non-decreasing.
        let late = result.windowTrace.filter { $0.at > 25 }.map(\.window)
        XCTAssertEqual(late, late.sorted())
    }

    func testT6LossyCellular() {
        var link = SimulatedUplink(bandwidth: 500.0 * Double(kb), rtt: 0.3, loss: 0.05)
        link.seed = 42
        let result = link.run(fileSize: 8 * mb, partSize: 128 * kb, network: .cellular)
        XCTAssertTrue(result.finished)
        XCTAssertGreaterThanOrEqual(result.stats.retries, 1)
        XCTAssertGreaterThanOrEqual(result.stats.decreases, 1)
        XCTAssertEqual(result.retriedCredits, 0, "a part that was retried earns no fast credit")
        // The window halves (and never more than once at a time) at the first decrease. The spec expected the
        // window to stay at or below the cellular start of 4 until then; on a fast link it legitimately grows first.
        let trace = result.windowTrace.map(\.window)
        if let drop = (1 ..< trace.count).first(where: { trace[$0] < trace[$0 - 1] }) {
            XCTAssertEqual(trace[drop], max(2, trace[drop - 1] / 2))
        } else {
            XCTFail("the window never decreased")
        }
    }

    func testT15Determinism() {
        let slow = SimulatedUplink(bandwidth: 60.0 * Double(kb), rtt: 0.15)
        let a = slow.run(fileSize: 2 * mb, partSize: 128 * kb, network: .cellular)
        let b = slow.run(fileSize: 2 * mb, partSize: 128 * kb, network: .cellular)
        XCTAssertEqual(a.stats, b.stats)
        XCTAssertEqual(a.finishTime, b.finishTime)
        let lossy = SimulatedUplink(bandwidth: 500.0 * Double(kb), rtt: 0.3, loss: 0.05)
        let c = lossy.run(fileSize: 8 * mb, partSize: 128 * kb, network: .cellular)
        let d = lossy.run(fileSize: 8 * mb, partSize: 128 * kb, network: .cellular)
        XCTAssertEqual(c.stats, d.stats)
        XCTAssertEqual(c.finishTime, d.finishTime)
    }

    // MARK: Window rules

    func testInitialWindows() {
        func initial(_ partSize: Int, _ network: UploadPartWindow.NetworkClass) -> Int {
            return UploadPartWindow(UploadPartWindow.Config(partSize: partSize, network: network)).window
        }
        XCTAssertEqual(initial(128 * kb, .wifi), 6)
        XCTAssertEqual(initial(128 * kb, .unknown), 6)
        XCTAssertEqual(initial(256 * kb, .wifi), 6)
        XCTAssertEqual(initial(512 * kb, .wifi), 3)
        XCTAssertEqual(initial(128 * kb, .cellular), 4)
        XCTAssertEqual(initial(256 * kb, .cellular), 2)
        XCTAssertEqual(initial(512 * kb, .cellular), 2)
    }

    func testT7HoldoffHalvesOnce() {
        var window = UploadPartWindow(UploadPartWindow.Config(partSize: 128 * kb, network: .wifi))
        for (index, finish) in [9.0, 9.1, 9.2].enumerated() {
            window.partStarted(id: Int64(index), bytes: 128 * kb, inFlight: 5, at: finish - 8.5)
        }
        window.partFinished(id: 0, at: 9.0)
        window.partFinished(id: 1, at: 9.1)
        window.partFinished(id: 2, at: 9.2)
        XCTAssertEqual(window.window, 3)
        XCTAssertEqual(window.stats.decreases, 1)
    }

    func testT8Floor() {
        var window = UploadPartWindow(UploadPartWindow.Config(partSize: 128 * kb, network: .wifi))
        var time = 0.0
        for index in 0 ..< 10 {
            window.partStarted(id: Int64(index), bytes: 128 * kb, inFlight: 5, at: time)
            window.partFinished(id: Int64(index), at: time + 9.0)
            time += 20.0
            XCTAssertGreaterThanOrEqual(window.window, 2)
        }
        XCTAssertEqual(window.window, 2)
    }

    func testT9AppLimitedDoesNotGrow() {
        var window = UploadPartWindow(UploadPartWindow.Config(partSize: 128 * kb, network: .wifi))
        let _ = self.feed(&window, count: 20, bytes: 128 * kb, duration: 0.3, spacing: 0.3, inFlight: 1)
        XCTAssertEqual(window.window, 6)
    }

    func testT10Caps() {
        for (partSize, expected) in [(128 * kb, 8), (256 * kb, 6), (512 * kb, 3)] {
            var window = UploadPartWindow(UploadPartWindow.Config(partSize: partSize, network: .wifi))
            let _ = self.feed(&window, count: 200, bytes: partSize, duration: 0.2, spacing: 0.05)
            XCTAssertEqual(window.stats.maxWindow, expected, "part size \(partSize)")
            XCTAssertLessThanOrEqual(window.window, 8)
        }
    }

    func testT11GoodputGuard() {
        var window = UploadPartWindow(UploadPartWindow.Config(partSize: 128 * kb, network: .cellular))
        XCTAssertEqual(window.window, 4)
        // Each part is fast (1.4 s) but one finishes every 2 s: 64 KB/s carries 3 parts in 6 s.
        let _ = self.feed(&window, count: 12, bytes: 128 * kb, duration: 1.4, spacing: 2.0)
        XCTAssertEqual(window.window, 4)
    }

    func testT12NetworkFlip() {
        var window = UploadPartWindow(UploadPartWindow.Config(partSize: 128 * kb, network: .wifi))
        let _ = self.feed(&window, count: 10, bytes: 128 * kb, duration: 0.2, spacing: 0.05)
        XCTAssertEqual(window.window, 8)
        window.networkChanged(.cellular, at: 5)
        XCTAssertEqual(window.window, 4)
        window.networkChanged(.wifi, at: 6)
        XCTAssertEqual(window.window, 4)
        XCTAssertEqual(window.stats.startNetwork, .wifi)
        XCTAssertEqual(window.stats.endNetwork, .wifi)
    }

    func testT13Restart() {
        var window = UploadPartWindow(UploadPartWindow.Config(partSize: 128 * kb, network: .wifi))
        let _ = self.feed(&window, count: 10, bytes: 128 * kb, duration: 0.2, spacing: 0.05)
        window.partStarted(id: 100, bytes: 128 * kb, inFlight: 5, at: 3)
        let before = window.stats
        window.restart(partSize: 512 * kb, at: 4)
        XCTAssertEqual(window.window, 3)
        XCTAssertEqual(window.stats.parts, before.parts)
        XCTAssertEqual(window.stats.maxWindow, before.maxWindow)
        // The part in flight before the restart is forgotten: its late finish counts for nothing.
        window.partFinished(id: 100, at: 30)
        XCTAssertEqual(window.stats.parts, before.parts)
        XCTAssertEqual(window.window, 3)
    }

    func testT14StallDecreasesOnce() {
        var window = UploadPartWindow(UploadPartWindow.Config(partSize: 128 * kb, network: .wifi))
        window.partStarted(id: 1, bytes: 128 * kb, inFlight: 5, at: 0)
        window.partStalled(id: 1, at: 8)
        XCTAssertEqual(window.window, 3)
        window.partFinished(id: 1, at: 20)
        XCTAssertEqual(window.window, 3)
        XCTAssertEqual(window.stats.decreases, 1)
        XCTAssertEqual(window.stats.stalls, 1)
    }

    func testRetriedPartEarnsNoCreditAndHalves() {
        var window = UploadPartWindow(UploadPartWindow.Config(partSize: 128 * kb, network: .wifi))
        window.partStarted(id: 1, bytes: 128 * kb, inFlight: 5, at: 0)
        window.partRetried(id: 1, at: 0.4, resumesAt: 0.9)
        XCTAssertEqual(window.window, 3)
        window.partFinished(id: 1, at: 1.1)
        XCTAssertEqual(window.window, 3, "a retried part is never a fast sample")
        XCTAssertEqual(window.stats.retries, 1)
    }

    func testFailureHalves() {
        var window = UploadPartWindow(UploadPartWindow.Config(partSize: 128 * kb, network: .wifi))
        window.partStarted(id: 1, bytes: 128 * kb, inFlight: 5, at: 0)
        window.partFailed(id: 1, at: 3)
        XCTAssertEqual(window.window, 3)
        XCTAssertEqual(window.stats.failures, 1)
    }
}
