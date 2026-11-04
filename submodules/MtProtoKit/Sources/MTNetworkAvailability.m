#import <MtProtoKit/MTNetworkAvailability.h>

#import <MtProtoKit/MTLogging.h>
#import <MtProtoKit/MTQueue.h>

#import <sys/socket.h>
#import <netinet/in.h>
#import <SystemConfiguration/SystemConfiguration.h>
#if TARGET_OS_OSX
#import <Network/Network.h>
#endif

#import <objc/message.h>

#if !TARGET_OS_OSX
static void MTAvailabilityCallback(SCNetworkReachabilityRef target, SCNetworkReachabilityFlags flags, void *info);

@class MTNetworkAvailability;

@interface MTNetworkAvailabilityContext : NSObject

@property (nonatomic, weak) MTNetworkAvailability *context;

@end

@implementation MTNetworkAvailabilityContext

@end

static const void *MTNetworkAvailabilityContextRetain(const void *info)
{
    return (__bridge_retained void *)((__bridge id)info);
}

static void MTNetworkAvailabilityContextRelease(const void *info)
{
    void *retainedThing = (__bridge void *)((__bridge id)info);
    __unused id unretainedThing = (__bridge_transfer id)retainedThing;
    unretainedThing = nil;
}
#endif

@interface MTNetworkAvailability ()
{
#if TARGET_OS_OSX
    nw_path_monitor_t _pathMonitor;
#else
    SCNetworkReachabilityRef _reachability;
#endif
    
    NSString *_lastReachabilityState;
}

@end

// One 5 s poll for all instances (one per transport) instead of a timer each.
// Accessed on networkAvailabilityQueue only.
#if !TARGET_OS_OSX
static NSHashTable<MTNetworkAvailability *> *MTNetworkAvailabilityPollingInstances = nil;
static dispatch_source_t MTNetworkAvailabilityPollTimer = nil;
#endif

@implementation MTNetworkAvailability

- (instancetype)initWithDelegate:(id<MTNetworkAvailabilityDelegate>)delegate
{
    self = [super init];
    if (self != nil)
    {
        _delegate = delegate;
        
#if TARGET_OS_OSX
        [[MTNetworkAvailability networkAvailabilityQueue] dispatchOnQueue:^
         {
             _lastReachabilityState = @"+";
             
             __weak MTNetworkAvailability *weakSelf = self;
             nw_path_monitor_t pathMonitor = nw_path_monitor_create();
             nw_path_monitor_set_queue(pathMonitor, [MTNetworkAvailability networkAvailabilityQueue].nativeQueue);
             nw_path_monitor_set_update_handler(pathMonitor, ^(nw_path_t path) {
                 __strong MTNetworkAvailability *strongSelf = weakSelf;
                 if (strongSelf != nil) {
                     [strongSelf updateNetworkIsAvailable:nw_path_get_status(path) == nw_path_status_satisfied];
                 }
             });
             nw_path_monitor_start(pathMonitor);
             _pathMonitor = pathMonitor;
         }];
#else
        [[MTNetworkAvailability networkAvailabilityQueue] dispatchOnQueue:^
         {
             struct sockaddr_in zeroAddress;
             bzero(&zeroAddress, sizeof(zeroAddress));
             zeroAddress.sin_len = sizeof(zeroAddress);
             zeroAddress.sin_family = AF_INET;
             
             _reachability = SCNetworkReachabilityCreateWithAddress(kCFAllocatorDefault, (const struct sockaddr *)&zeroAddress);
             if (_reachability != NULL)
             {
                 MTNetworkAvailabilityContext *availabilityContext = [[MTNetworkAvailabilityContext alloc] init];
                 availabilityContext.context = self;
                 SCNetworkReachabilityContext context = { 0, (__bridge void *)availabilityContext, &MTNetworkAvailabilityContextRetain, &MTNetworkAvailabilityContextRelease, NULL };
                 
                 [self updateReachability:kSCNetworkReachabilityFlagsReachable notify:false];
                 [self updateFlags:true];
                 
                 [MTNetworkAvailability addPollingInstance:self];
                 
                 if (SCNetworkReachabilitySetCallback(_reachability, &MTAvailabilityCallback, &context))
                     SCNetworkReachabilitySetDispatchQueue(_reachability, [MTNetworkAvailability networkAvailabilityQueue].nativeQueue);
             }
         }];
#endif
    }
    return self;
}

- (void)dealloc
{
#if TARGET_OS_OSX
    nw_path_monitor_t pathMonitor = _pathMonitor;
    _pathMonitor = nil;
    
    [[MTNetworkAvailability networkAvailabilityQueue] dispatchOnQueue:^{
        if (pathMonitor != nil) {
            nw_path_monitor_cancel(pathMonitor);
        }
    }];
#else
    SCNetworkReachabilityRef reachability = _reachability;
    _reachability = nil;
    
    [[MTNetworkAvailability networkAvailabilityQueue] dispatchOnQueue:^{
        SCNetworkReachabilitySetCallback(reachability, NULL, NULL);
        SCNetworkReachabilitySetDispatchQueue(reachability, NULL);
        CFRelease(reachability);
    }];
#endif
}

+ (MTQueue *)networkAvailabilityQueue
{
    static MTQueue *queue = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^
                  {
                      queue = [[MTQueue alloc] initWithName:"org.mtproto.MTNetwotkAvailability"];
                  });
    return queue;
}

#if !TARGET_OS_OSX
+ (void)addPollingInstance:(MTNetworkAvailability *)instance
{
    if (MTNetworkAvailabilityPollingInstances == nil) {
        MTNetworkAvailabilityPollingInstances = [NSHashTable weakObjectsHashTable];
    }
    [MTNetworkAvailabilityPollingInstances addObject:instance];
    
    if (MTNetworkAvailabilityPollTimer == nil) {
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, [MTNetworkAvailability networkAvailabilityQueue].nativeQueue);
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), (uint64_t)(5.0 * NSEC_PER_SEC), (uint64_t)(0.5 * NSEC_PER_SEC));
        dispatch_source_set_event_handler(timer, ^{
            NSArray<MTNetworkAvailability *> *instances = MTNetworkAvailabilityPollingInstances.allObjects;
            if (instances.count == 0) {
                dispatch_source_cancel(MTNetworkAvailabilityPollTimer);
                MTNetworkAvailabilityPollTimer = nil;
                return;
            }
            for (MTNetworkAvailability *availability in instances) {
                [availability updateFlags:true];
            }
        });
        MTNetworkAvailabilityPollTimer = timer;
        dispatch_resume(timer);
    }
}
#endif

#if TARGET_OS_OSX
- (void)updateNetworkIsAvailable:(bool)isNetworkAvailable
{
    NSString *currentReachabilityState = isNetworkAvailable ? @"+" : @"-";
    if (![currentReachabilityState isEqualToString:_lastReachabilityState])
    {
        _lastReachabilityState = currentReachabilityState;
        if (MTLogEnabled()) {
            MTLog(@"[MTNetworkAvailability#%p state: %@]", self, _lastReachabilityState);
        }
        
        id<MTNetworkAvailabilityDelegate> delegate = _delegate;
        if ([delegate respondsToSelector:@selector(networkAvailabilityChanged:networkIsAvailable:)])
            [delegate networkAvailabilityChanged:self networkIsAvailable:isNetworkAvailable];
    }
}
#else
- (void)updateFlags:(bool)notify
{
    [[MTNetworkAvailability networkAvailabilityQueue] dispatchOnQueue:^
     {
         
         if (_reachability != nil)
         {
             SCNetworkReachabilityFlags currentFlags = 0;
             if (SCNetworkReachabilityGetFlags(_reachability, &currentFlags))
                 [self updateReachability:currentFlags notify:notify];
         }
     }];
}

- (void)updateReachability:(SCNetworkReachabilityFlags)flags notify:(bool)notify
{
    [[MTNetworkAvailability networkAvailabilityQueue] dispatchOnQueue:^
     {
         BOOL isReachable = ((flags & kSCNetworkReachabilityFlagsReachable) != 0);
         BOOL canConnectionAutomatically = (((flags & kSCNetworkReachabilityFlagsConnectionOnDemand ) != 0) ||
                                            ((flags & kSCNetworkReachabilityFlagsConnectionOnTraffic) != 0));
         BOOL canConnectWithoutUserInteraction = (canConnectionAutomatically &&
                                                  (flags & kSCNetworkReachabilityFlagsInterventionRequired) == 0);
         BOOL isNetworkReachable = isReachable;
         
         bool isWWAN = false;
#if TARGET_OS_IPHONE
         isWWAN = (flags & kSCNetworkReachabilityFlagsIsWWAN);
#endif
         NSString *currentReachabilityState = [[NSString alloc] initWithFormat:@"%s_%s_%s", isWWAN ? "M" : "L", canConnectWithoutUserInteraction ? "+U" : "-U", isNetworkReachable ? "+" : "-"];
         if (![currentReachabilityState isEqualToString:_lastReachabilityState])
         {
             _lastReachabilityState = currentReachabilityState;
             if (MTLogEnabled()) {
                 MTLog(@"[MTNetworkAvailability#%p state: %@]", self, _lastReachabilityState);
             }
             
             if (notify)
             {
                 id<MTNetworkAvailabilityDelegate> delegate = _delegate;
                 if ([delegate respondsToSelector:@selector(networkAvailabilityChanged:networkIsAvailable:)])
                     [delegate networkAvailabilityChanged:self networkIsAvailable:isNetworkReachable];
             }
         }
     }];
}
#endif

@end

#if !TARGET_OS_OSX
static void MTAvailabilityCallback(__unused SCNetworkReachabilityRef target, SCNetworkReachabilityFlags flags, void *info)
{
    MTNetworkAvailabilityContext *availabilityContext = ((__bridge MTNetworkAvailabilityContext *)info);
    MTNetworkAvailability *availability = availabilityContext.context;
    [availability updateReachability:flags notify:true];
}
#endif
