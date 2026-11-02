#import <LegacyComponents/TGVideoCameraStabilization.h>

AVCaptureVideoStabilizationMode TGVideoMessageStabilizationMode(bool connectionSupportsStabilization, bool formatSupportsStandard) {
    if (connectionSupportsStabilization && formatSupportsStandard) {
        return AVCaptureVideoStabilizationModeStandard;
    }
    return AVCaptureVideoStabilizationModeOff;
}
