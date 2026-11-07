#import "MTTcpResponseTimeoutPolicy.h"

static const NSTimeInterval MTTcpUsualResponseTimeout = 12.0;
static const NSTimeInterval MTTcpMinFirstResponseTimeout = 3.0;
static const double MTTcpFirstResponseSetupMultiplier = 10.0;

NSTimeInterval MTTcpResponseTimeoutForSend(bool awaitingFirstResponse, NSTimeInterval connectDuration, NSUInteger dataLength) {
    const NSTimeInterval sizeAllowance = (double)dataLength / (12.0 * 1024.0);
    const NSTimeInterval usual = MTTcpUsualResponseTimeout + sizeAllowance;
    if (!awaitingFirstResponse || connectDuration < 0.0) {
        return usual;
    }
    const NSTimeInterval first = MAX(MTTcpMinFirstResponseTimeout, connectDuration * MTTcpFirstResponseSetupMultiplier) + sizeAllowance;
    return MIN(first, usual);
}
