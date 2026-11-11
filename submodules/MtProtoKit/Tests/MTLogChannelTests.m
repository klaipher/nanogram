#import <XCTest/XCTest.h>

#import <MtProtoKit/MTLogging.h>

// Which MTProto log lines are written. The short lines are always kept; the request and response dumps need the
// "Network protocol dumps" switch; the MTContext keychain dumps are also skipped in an app extension (the notification
// service logged them on every push).
@interface MTLogChannelTests : XCTestCase
@end

@implementation MTLogChannelTests

- (void)testShortLinesAreAlwaysLogged {
    XCTAssertTrue(MTShouldLogMT(MTLogChannelShort, false, false));
    XCTAssertTrue(MTShouldLogMT(MTLogChannelShort, false, true));
    XCTAssertTrue(MTShouldLogMT(MTLogChannelShort, true, true));
}

- (void)testVerboseLinesNeedTheDumpsSwitch {
    XCTAssertFalse(MTShouldLogMT(MTLogChannelVerbose, false, false));
    XCTAssertTrue(MTShouldLogMT(MTLogChannelVerbose, true, false));
}

- (void)testContextDumpsNeedTheSwitchAndNoAppExtension {
    XCTAssertFalse(MTShouldLogMT(MTLogChannelContextDump, false, false));
    XCTAssertTrue(MTShouldLogMT(MTLogChannelContextDump, true, false));
    XCTAssertFalse(MTShouldLogMT(MTLogChannelContextDump, true, true));
}

@end
