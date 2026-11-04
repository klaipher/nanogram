#import <XCTest/XCTest.h>
#import <TargetConditionals.h>
#import <objc/runtime.h>

#import <MtProtoKit/MTNetworkAvailability.h>

static NSInteger MTNetworkAvailabilityPollTestsFlagReads = 0;

@interface MTNetworkAvailabilityPollTestsDelegate : NSObject <MTNetworkAvailabilityDelegate>
@end

@implementation MTNetworkAvailabilityPollTestsDelegate
@end

@interface MTNetworkAvailabilityPollTests : XCTestCase
@end

@implementation MTNetworkAvailabilityPollTests

- (void)testAvailabilityDoesNotPollTheReachabilityFlags {
    SEL selector = NSSelectorFromString(@"updateFlags:");
    Method method = class_getInstanceMethod([MTNetworkAvailability class], selector);
    IMP original = NULL;
    if (method != NULL) {
        original = method_getImplementation(method);
        IMP counting = imp_implementationWithBlock(^(id object, bool notify) {
            @synchronized ([MTNetworkAvailabilityPollTests class]) {
                MTNetworkAvailabilityPollTestsFlagReads += 1;
            }
            ((void (*)(id, SEL, bool))original)(object, selector, notify);
        });
        method_setImplementation(method, counting);
    }
    MTNetworkAvailabilityPollTestsDelegate *delegate = [[MTNetworkAvailabilityPollTestsDelegate alloc] init];
    MTNetworkAvailability *availability = [[MTNetworkAvailability alloc] initWithDelegate:delegate];
    XCTestExpectation *waited = [self expectationWithDescription:@"waited"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(11.5 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        [waited fulfill];
    });
    [self waitForExpectations:@[waited] timeout:20.0];
    NSInteger reads = 0;
    @synchronized ([MTNetworkAvailabilityPollTests class]) {
        reads = MTNetworkAvailabilityPollTestsFlagReads;
    }
    if (method != NULL) {
        method_setImplementation(method, original);
    }
    NSLog(@"MTNetworkAvailability: %ld reachability flag reads in 11.5 s", (long)reads);
#if TARGET_OS_OSX
    // macOS watches the path with nw_path_monitor and never polls the flags. iOS keeps the shared
    // poll timer, which reads them on purpose.
    XCTAssertLessThanOrEqual(reads, 1);
#endif
    (void)availability;
}

@end
