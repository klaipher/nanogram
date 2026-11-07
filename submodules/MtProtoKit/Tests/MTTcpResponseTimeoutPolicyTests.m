#import <XCTest/XCTest.h>

#import "MTTcpResponseTimeoutPolicy.h"

// After the app came back from another app, a fresh TCP connection to the DC connected in 50 ms and
// the first requests went out, but no byte ever came back; the app showed "Updating…" for the full
// 12 s response timeout, reconnected and got the answer in 50 ms (owner's log, 2026-11-08 00:07:17).
// The first response of a fresh direct connection now has a timeout that follows how fast the
// connection was set up; everything else keeps the 12 s rule.
@interface MTTcpResponseTimeoutPolicyTests : XCTestCase
@end

@implementation MTTcpResponseTimeoutPolicyTests

- (void)testAFastFreshConnectionGivesUpOnASilentServerAfterThreeSeconds {
    XCTAssertEqualWithAccuracy(MTTcpResponseTimeoutForSend(true, 0.05, 0), 3.0, 0.0001);
}

- (void)testASlowConnectionScalesTheFirstResponseTimeoutWithItsSetupTime {
    // An 800 ms connect (a slow cellular link) waits 8 s for the first byte.
    XCTAssertEqualWithAccuracy(MTTcpResponseTimeoutForSend(true, 0.8, 0), 8.0, 0.0001);
}

- (void)testTheFirstResponseTimeoutNeverExceedsTheUsualOne {
    XCTAssertEqualWithAccuracy(MTTcpResponseTimeoutForSend(true, 5.0, 0), 12.0, 0.0001);
}

- (void)testLargeFirstUploadsKeepTheirSizeAllowance {
    // 120 KB adds 10 s, as the usual rule does.
    XCTAssertEqualWithAccuracy(MTTcpResponseTimeoutForSend(true, 0.05, 120 * 1024), 13.0, 0.0001);
    XCTAssertEqualWithAccuracy(MTTcpResponseTimeoutForSend(false, 0.05, 120 * 1024), 22.0, 0.0001);
}

- (void)testOnceDataArrivedOrWithoutAMeasuredConnectTheUsualRuleApplies {
    XCTAssertEqualWithAccuracy(MTTcpResponseTimeoutForSend(false, 0.05, 0), 12.0, 0.0001);
    XCTAssertEqualWithAccuracy(MTTcpResponseTimeoutForSend(true, -1.0, 0), 12.0, 0.0001);
}

@end
