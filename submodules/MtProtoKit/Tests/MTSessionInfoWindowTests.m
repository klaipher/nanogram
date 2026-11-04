#import <XCTest/XCTest.h>

#import <MtProtoKit/MTSessionInfo.h>

// Server and client message ids carry unix time in their upper 32 bits.
static int64_t MTSessionInfoWindowTestsMessageId(int64_t seconds, int64_t serial) {
    return (seconds << 32) + serial * 4 + 1;
}

@interface MTSessionInfoWindowTests : XCTestCase
@end

@implementation MTSessionInfoWindowTests

- (MTSessionInfo *)makeSessionInfo {
    return [[MTSessionInfo alloc] initWithSessionId:1 context:nil];
}

- (void)testDuplicatesAreDetected {
    MTSessionInfo *sessionInfo = [self makeSessionInfo];
    int64_t first = MTSessionInfoWindowTestsMessageId(1700000000, 1);
    int64_t second = MTSessionInfoWindowTestsMessageId(1700000000, 2);
    XCTAssertFalse([sessionInfo messageProcessed:first]);
    [sessionInfo setMessageProcessed:first];
    XCTAssertTrue([sessionInfo messageProcessed:first]);
    XCTAssertFalse([sessionInfo messageProcessed:second]);
    [sessionInfo setMessageProcessed:second];
    [sessionInfo setMessageProcessed:second];
    XCTAssertTrue([sessionInfo messageProcessed:second]);
}

- (void)testOutOfOrderIdsInsideTheWindowAreTracked {
    MTSessionInfo *sessionInfo = [self makeSessionInfo];
    for (int64_t serial = 100; serial > 0; serial -= 2) {
        [sessionInfo setMessageProcessed:MTSessionInfoWindowTestsMessageId(1700000000, serial)];
    }
    for (int64_t serial = 1; serial <= 100; serial++) {
        bool expected = serial % 2 == 0;
        XCTAssertEqual([sessionInfo messageProcessed:MTSessionInfoWindowTestsMessageId(1700000000, serial)], expected, @"serial %lld", serial);
    }
}

- (void)testAFullWindowTreatsOlderIdsAsReplays {
    MTSessionInfo *sessionInfo = [self makeSessionInfo];
    for (int64_t serial = 1; serial <= 5000; serial++) {
        [sessionInfo setMessageProcessed:MTSessionInfoWindowTestsMessageId(1700000000, serial)];
    }
    // The newest 2000 are kept exactly.
    XCTAssertTrue([sessionInfo messageProcessed:MTSessionInfoWindowTestsMessageId(1700000000, 5000)]);
    XCTAssertTrue([sessionInfo messageProcessed:MTSessionInfoWindowTestsMessageId(1700000000, 3001)]);
    // Ids below the window are still never processed twice.
    XCTAssertTrue([sessionInfo messageProcessed:MTSessionInfoWindowTestsMessageId(1700000000, 1)]);
    XCTAssertTrue([sessionInfo messageProcessed:MTSessionInfoWindowTestsMessageId(1700000000, 3000)]);
    // A new id is new, and a gap inside the window stays unprocessed.
    XCTAssertFalse([sessionInfo messageProcessed:MTSessionInfoWindowTestsMessageId(1700000001, 1)]);
    int64_t gap = MTSessionInfoWindowTestsMessageId(1700000000, 4000) + 2;
    XCTAssertFalse([sessionInfo messageProcessed:gap]);
    [sessionInfo setMessageProcessed:gap];
    XCTAssertTrue([sessionInfo messageProcessed:gap]);
    XCTAssertTrue([sessionInfo messageProcessed:MTSessionInfoWindowTestsMessageId(1700000000, 5000)]);
}

- (void)testSentOnceIdsUseTheSameWindow {
    MTSessionInfo *sessionInfo = [self makeSessionInfo];
    int64_t messageId = MTSessionInfoWindowTestsMessageId(1700000000, 7) - 1;
    XCTAssertFalse([sessionInfo wasMessageSentOnce:messageId]);
    [sessionInfo setMessageWasSentOnce:messageId];
    XCTAssertTrue([sessionInfo wasMessageSentOnce:messageId]);
    for (int64_t serial = 10; serial < 2100; serial++) {
        [sessionInfo setMessageWasSentOnce:MTSessionInfoWindowTestsMessageId(1700000000, serial) - 1];
    }
    XCTAssertTrue([sessionInfo wasMessageSentOnce:messageId]);
    XCTAssertFalse([sessionInfo wasMessageSentOnce:MTSessionInfoWindowTestsMessageId(1700000001, 1) - 1]);
}

- (void)testContainerMappingsOlderThanAnHourAreDropped {
    MTSessionInfo *sessionInfo = [self makeSessionInfo];
    int64_t start = 1700000000;
    for (int64_t index = 0; index < 300; index++) {
        int64_t containerId = MTSessionInfoWindowTestsMessageId(start + index * 60, 0) - 1;
        [sessionInfo addContainerMessageIdMapping:containerId childMessageIds:@[@(containerId - 4), @(containerId - 8)]];
    }
    // 300 containers a minute apart: the prune at 256 keeps only the last hour (61 of them), and later ones are added.
    XCTAssertLessThanOrEqual([sessionInfo containerMessageIdMappingCount], (NSUInteger)(61 + 44));
    int64_t newest = MTSessionInfoWindowTestsMessageId(start + 299 * 60, 0) - 1;
    NSArray *children = [sessionInfo messageIdsInContainer:newest];
    XCTAssertEqualObjects(children, (@[@(newest - 4), @(newest - 8)]));
    int64_t oldest = MTSessionInfoWindowTestsMessageId(start, 0) - 1;
    XCTAssertNil([sessionInfo messageIdsInContainer:oldest]);
}

- (void)testRecentContainerMappingsAreKept {
    MTSessionInfo *sessionInfo = [self makeSessionInfo];
    int64_t start = 1700000000;
    for (int64_t index = 0; index < 1000; index++) {
        int64_t containerId = MTSessionInfoWindowTestsMessageId(start, index * 4) - 1;
        [sessionInfo addContainerMessageIdMapping:containerId childMessageIds:@[@(containerId - 4)]];
    }
    XCTAssertEqual([sessionInfo containerMessageIdMappingCount], (NSUInteger)1000);
    int64_t first = MTSessionInfoWindowTestsMessageId(start, 0) - 1;
    NSArray *after = [sessionInfo messageIdsInContainersAfterMessageId:first];
    XCTAssertEqual(after.count, (NSUInteger)1000);
}

@end
