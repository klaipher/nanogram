import XCTest
@testable import WalletContext

final class WalletStateRetryPolicyTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func delays(count: Int, demand: Bool) -> [TimeInterval] {
        var policy = WalletStateRetryPolicy()
        var result: [TimeInterval] = []
        for _ in 0..<count {
            policy.recordFailure()
            result.append(policy.delay(hasRefreshDemand: demand))
        }
        return result
    }

    /// Runs the automatic loop: the gate is asked, a `.wait` is slept (in steps of at most `foregroundEvery`, as if a
    /// foreground or network-resume event asked again every few seconds) and every attempt fails with `kind`.
    /// Returns the attempt times in seconds.
    private func simulate(
        kind: WalletStateFailureKind,
        demand: Bool,
        duration: TimeInterval,
        foregroundEvery: TimeInterval? = nil
    ) -> [TimeInterval] {
        var policy = WalletStateRetryPolicy()
        var attempts: [TimeInterval] = []
        var t: TimeInterval = 0
        while t < duration {
            let now = start.addingTimeInterval(t)
            switch policy.gate(hasRefreshDemand: demand, now: now) {
            case .allow:
                policy.recordAttempt(at: now)
                policy.recordFailure(kind, at: now)
                attempts.append(t)
            case let .wait(seconds):
                t += foregroundEvery.map { min(seconds, $0) } ?? seconds
            case .blocked:
                return attempts
            }
        }
        return attempts
    }

    private func gaps(_ attempts: [TimeInterval]) -> [TimeInterval] {
        zip(attempts.dropFirst(), attempts).map { $0 - $1 }
    }

    func testUnattendedDelayDoublesFromFiveSecondsAndStopsAtTenMinutes() {
        XCTAssertEqual(delays(count: 10, demand: false), [5, 10, 20, 40, 80, 160, 320, 600, 600, 600])
    }

    func testVisibleWalletCapsTheWait() {
        XCTAssertEqual(delays(count: 6, demand: true), [5, 10, 20, 20, 20, 20])
    }

    func testDemandAfterLongBackoffIsCappedImmediately() {
        var policy = WalletStateRetryPolicy()
        for _ in 0..<9 { policy.recordFailure() }
        XCTAssertEqual(policy.delay(hasRefreshDemand: false), 600)
        XCTAssertEqual(policy.delay(hasRefreshDemand: true), 20)
    }

    func testSuccessStartsOverAtFiveSeconds() {
        var policy = WalletStateRetryPolicy()
        policy.recordFailure()
        policy.recordFailure()
        policy.reset()
        policy.recordFailure()
        XCTAssertEqual(policy.delay(hasRefreshDemand: false), 5)
    }

    func testAuthoritativeFailureStopsAllRetries() {
        var policy = WalletStateRetryPolicy()
        policy.recordAttempt(at: start)
        policy.recordFailure(.authoritative, at: start)
        XCTAssertEqual(policy.gate(hasRefreshDemand: false, now: start.addingTimeInterval(86_400)), .blocked)
        XCTAssertEqual(policy.gate(hasRefreshDemand: true, now: start.addingTimeInterval(86_400)), .blocked)
        XCTAssertEqual(simulate(kind: .authoritative, demand: false, duration: 86_400, foregroundEvery: 3), [0])
    }

    func testOpeningTheWalletLiftsAnAuthoritativeStop() {
        var policy = WalletStateRetryPolicy()
        policy.recordAttempt(at: start)
        policy.recordFailure(.authoritative, at: start)
        policy.resetForUserDemand()
        XCTAssertEqual(policy.gate(hasRefreshDemand: true, now: start.addingTimeInterval(1)), .allow)
    }

    func testAFreshPolicyAllowsTheFirstAttemptOfALaunch() {
        XCTAssertEqual(WalletStateRetryPolicy().gate(hasRefreshDemand: false, now: start), .allow)
    }

    func testTransientBackoffReachesTheCapDespiteRepeatedForegrounds() {
        // A foreground event every 3 s must not shorten any wait.
        let attempts = simulate(kind: .transient(minimumDelay: 0), demand: false, duration: 1500, foregroundEvery: 3)
        XCTAssertEqual(Array(gaps(attempts).prefix(7)), [5, 10, 20, 40, 80, 160, 320])
        XCTAssertEqual(attempts.first, 0)
    }

    func testFloodWaitIsHonouredAsMinimumDelay() {
        var policy = WalletStateRetryPolicy()
        policy.recordAttempt(at: start)
        policy.recordFailure(.transient(minimumDelay: 120), at: start)
        XCTAssertEqual(policy.gate(hasRefreshDemand: true, now: start.addingTimeInterval(30)), .wait(90))
        XCTAssertEqual(policy.gate(hasRefreshDemand: true, now: start.addingTimeInterval(120)), .allow)
    }

    func testBackoffSurvivesBackgroundAndResumeButNotWalletDemand() {
        var policy = WalletStateRetryPolicy()
        for i in 0..<4 {
            let now = start.addingTimeInterval(Double(i) * 100)
            policy.recordAttempt(at: now)
            policy.recordFailure(.transient(minimumDelay: 0), at: now)
        }
        // Fourth failure at t=300 sets a 40 s delay; a resume at t=310 still has to wait 30 s.
        XCTAssertEqual(policy.gate(hasRefreshDemand: false, now: start.addingTimeInterval(310)), .wait(30))
        policy.resetForUserDemand()
        XCTAssertEqual(policy.gate(hasRefreshDemand: true, now: start.addingTimeInterval(310)), .allow)
    }

    func testWalletScreenDemandStillRetriesQuickly() {
        let attempts = simulate(kind: .transient(minimumDelay: 0), demand: true, duration: 200)
        XCTAssertEqual(Array(gaps(attempts).prefix(4)), [5, 10, 20, 20])
        XCTAssertLessThanOrEqual(gaps(attempts).max() ?? 0, 20)
    }

    func testUnattendedAttemptsPerHourAreBounded() {
        let hour = simulate(kind: .transient(minimumDelay: 0), demand: false, duration: 3599)
        XCTAssertLessThanOrEqual(hour.count, WalletStateRetryPolicy.maximumAttemptsPerWindow)
        let day = simulate(kind: .transient(minimumDelay: 0), demand: false, duration: 86_400)
        XCTAssertLessThanOrEqual(day.count, 24 * WalletStateRetryPolicy.maximumAttemptsPerWindow)
        // Any sliding hour holds at most the cap.
        for attempt in day {
            let inWindow = day.filter { $0 >= attempt && $0 < attempt + 3600 }.count
            XCTAssertLessThanOrEqual(inWindow, WalletStateRetryPolicy.maximumAttemptsPerWindow)
        }
    }

    func testAttemptsPerHourAreBoundedWhileTheWalletIsVisible() {
        let hour = simulate(kind: .transient(minimumDelay: 0), demand: true, duration: 3599)
        XCTAssertLessThanOrEqual(hour.count, WalletStateRetryPolicy.maximumAttemptsPerWindowWithDemand)
    }

    func testHourlyCapWaitsForTheWindowToSlide() {
        var policy = WalletStateRetryPolicy()
        for i in 0..<WalletStateRetryPolicy.maximumAttemptsPerWindow {
            policy.recordAttempt(at: start.addingTimeInterval(Double(i)))
        }
        XCTAssertEqual(policy.gate(hasRefreshDemand: false, now: start.addingTimeInterval(100)), .wait(3500))
    }
}
