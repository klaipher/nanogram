import XCTest
@testable import TelegramCore

/// The chat screen refreshes the peer's full data when it appears. The peer view it opened just before has
/// often started the same fetch (users.getFullUser, or channels.getFullChannel + channels.getParticipant)
/// about 0.6 s earlier; the refresh is skipped only while that fetch is recent and still running or has
/// succeeded.
final class ChatOpenCachedPeerDataRefreshTests: XCTestCase {
    private let now: Double = 800_000_000.0
    private let window = chatOpenCachedPeerDataRefreshWindow

    private func isRedundant(startedAgo: Double?, _ state: CachedPeerDataFetchState) -> Bool {
        return chatOpenCachedPeerDataRefreshIsRedundant(now: self.now, fetchStartedAt: startedAgo.map { self.now - $0 }, fetchState: state, window: self.window)
    }

    func testWithoutAnEarlierFetchTheChatRefreshes() {
        XCTAssertFalse(self.isRedundant(startedAgo: nil, .none))
    }

    func testAFetchStillRunningFromTheChatsPeerViewIsNotRepeated() {
        XCTAssertTrue(self.isRedundant(startedAgo: 0.6, .inFlight))
    }

    func testAFetchThatJustSucceededIsNotRepeated() {
        XCTAssertTrue(self.isRedundant(startedAgo: 0.6, .succeeded))
    }

    func testAFailedFetchIsRepeated() {
        XCTAssertFalse(self.isRedundant(startedAgo: 0.6, .failed))
    }

    func testACancelledFetchIsRepeated() {
        // removePeerView cancels the fetch when its last view goes away; nothing was stored by it.
        XCTAssertFalse(self.isRedundant(startedAgo: 0.6, .cancelled))
    }

    func testAnOlderFetchIsRepeated() {
        XCTAssertFalse(self.isRedundant(startedAgo: 6.0, .inFlight))
        XCTAssertFalse(self.isRedundant(startedAgo: 6.0, .succeeded))
        XCTAssertFalse(self.isRedundant(startedAgo: self.window, .succeeded))
    }

    func testAFetchStartedInTheFutureIsRepeated() {
        // The wall clock moved back: the start cannot be trusted as recent.
        XCTAssertFalse(self.isRedundant(startedAgo: -1.0, .succeeded))
        XCTAssertFalse(self.isRedundant(startedAgo: -1.0, .inFlight))
    }

    func testAStateWithoutAStartTimeIsRepeated() {
        XCTAssertFalse(self.isRedundant(startedAgo: nil, .inFlight))
        XCTAssertFalse(self.isRedundant(startedAgo: nil, .succeeded))
    }

    func testTheWindowCoversTheMeasuredGapAndStaysFarBelowTheViewThrottle() {
        // Measured on device (TestFlight 202611232311): the second fetch went out 0.6-0.7 s after the first.
        XCTAssertGreaterThan(self.window, 1.0)
        // A reopen inside the peer view's 5-minute throttle must still refresh as upstream does.
        XCTAssertLessThan(self.window, 60.0)
    }
}
