#ifndef CpuProfiler_h
#define CpuProfiler_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// An in-process sampling profiler.
///
/// On each tick every thread is inspected for its accumulated CPU time, and the ones
/// the kernel reports as running are suspended just long enough to read their registers
/// and walk the frame-pointer chain. Nothing is allocated and no lock is taken while a
/// thread is suspended: if the suspended thread happens to hold the allocator lock, a
/// single malloc in the sampler deadlocks the process.
@interface CpuProfiler : NSObject

/// Samples all threads for `duration` seconds at `sampleRate` samples per second and
/// produces a text report: per-thread CPU shares followed by a merged call tree per
/// thread, with a Binary Images footer so the frames can be symbolicated offline
/// against the matching dSYM.
///
/// The completion runs on the main queue. If a profile is already running, it is
/// called immediately with nil.
+ (void)collectProfileWithDuration:(NSTimeInterval)duration
                        sampleRate:(double)sampleRate
                        completion:(void (^)(NSString * _Nullable report))completion;

@property (class, nonatomic, readonly) BOOL isRunning;

@end

/// Debug Settings "Frame hitches: log with main-thread stacks": samples the main thread every few
/// milliseconds into a fixed ring buffer (about 12 s deep), so the stack of a stall that just ended can be
/// read back. Sampling suspends the main thread for a few microseconds per sample and allocates nothing
/// while it is suspended. Off unless started.
@interface MainThreadSampler : NSObject

/// Starts sampling. Must be called on the main thread. Does nothing if already running.
+ (void)startWithInterval:(NSTimeInterval)interval;

/// Stops sampling. The ring keeps its samples until the next start.
+ (void)stop;

@property (class, nonatomic, readonly) BOOL isRunning;

/// Copies the raw samples taken between two `CACurrentMediaTime()` instants. Cheap (a memcpy), so it
/// can run right after a stall; nil if there are none.
+ (nullable NSData *)captureFrom:(double)startTime to:(double)endTime;

/// A merged main-thread call tree of a capture, with a Binary Images footer for offline symbolication.
+ (NSString *)reportForCapture:(NSData *)capture;

@end

NS_ASSUME_NONNULL_END

#endif /* CpuProfiler_h */
