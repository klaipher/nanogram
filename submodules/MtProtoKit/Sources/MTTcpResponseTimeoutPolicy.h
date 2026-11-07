#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Nanogram: how long a TCP connection waits for a byte of response after sending `dataLength` bytes.
/// The usual rule (upstream) is 12 s plus 1 s per 12 KB. While a fresh direct connection is still waiting
/// for its first byte (`awaitingFirstResponse`) and its setup time is known (`connectDuration` >= 0), the
/// wait is max(3 s, 10 × setup time) plus the same size allowance, never more than the usual rule: a
/// connection that set up in 50 ms and stays silent for 3 s is dead (seen after switching back from
/// another app), and reconnecting then answers in milliseconds instead of after 12 s of "Updating…".
NSTimeInterval MTTcpResponseTimeoutForSend(bool awaitingFirstResponse, NSTimeInterval connectDuration, NSUInteger dataLength);

#ifdef __cplusplus
}
#endif
