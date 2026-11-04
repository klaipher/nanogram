#import <XCTest/XCTest.h>

#import <MtProtoKit/MTTimer.h>

@interface MTTimerLeewayTests : XCTestCase
@end

@implementation MTTimerLeewayTests

- (void)testShortTimersGetNoLeeway {
    XCTAssertEqual(MTTimerLeewaySeconds(0.0), 0.0);
    XCTAssertEqual(MTTimerLeewaySeconds(0.25), 0.0);
    XCTAssertEqual(MTTimerLeewaySeconds(0.999), 0.0);
}

- (void)testLeewayIsATenthOfTheTimeoutUpToOneSecond {
    XCTAssertEqualWithAccuracy(MTTimerLeewaySeconds(1.0), 0.1, 1e-9);
    XCTAssertEqualWithAccuracy(MTTimerLeewaySeconds(3.0), 0.3, 1e-9);
    XCTAssertEqualWithAccuracy(MTTimerLeewaySeconds(5.0), 0.5, 1e-9);
    XCTAssertEqualWithAccuracy(MTTimerLeewaySeconds(10.0), 1.0, 1e-9);
    XCTAssertEqualWithAccuracy(MTTimerLeewaySeconds(60.0), 1.0, 1e-9);
}

- (void)testInvalidTimeoutsGetNoLeeway {
    XCTAssertEqual(MTTimerLeewaySeconds(-5.0), 0.0);
    XCTAssertEqual(MTTimerLeewaySeconds(NAN), 0.0);
}

- (void)testATimerStillFiresWithItsLeeway {
    XCTestExpectation *fired = [self expectationWithDescription:@"fired"];
    CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
    __block CFAbsoluteTime firedAt = 0.0;
    MTTimer *timer = [[MTTimer alloc] initWithTimeout:1.0 repeat:false completion:^{
        firedAt = CFAbsoluteTimeGetCurrent();
        [fired fulfill];
    } queue:dispatch_get_main_queue()];
    [timer start];
    [self waitForExpectations:@[fired] timeout:5.0];
    XCTAssertGreaterThanOrEqual(firedAt - started, 0.99);
}

@end
