

#import <Foundation/Foundation.h>

// How late the system may fire an MTTimer so it can share a wake-up with other timers:
// min(10% of the timeout, 1 s) for timeouts of 1 s or longer, none below that. Every MTTimer is a
// network timeout, retry or back-off nobody sees, the same class SwiftSignalKit's `.automatic` covers.
FOUNDATION_EXTERN NSTimeInterval MTTimerLeewaySeconds(NSTimeInterval timeout);

@interface MTTimer : NSObject

@property (nonatomic) NSTimeInterval timeoutDate;

- (id)initWithTimeout:(NSTimeInterval)timeout repeat:(bool)repeat completion:(dispatch_block_t)completion queue:(dispatch_queue_t)queue;
- (void)start;
- (void)fireAndInvalidate;
- (void)invalidate;
- (bool)isScheduled;
- (void)resetTimeout:(NSTimeInterval)timeout;
- (NSTimeInterval)remainingTime;

@end
