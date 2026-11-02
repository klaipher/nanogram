#import <AVFoundation/AVFoundation.h>

#ifdef __cplusplus
extern "C" {
#endif

/// The stabilization the round-video (video message) camera asks for: standard when the connection and the active
/// format support it, otherwise off. The same choice as CameraNeo's (`CameraNeo.configureVideoStabilization`).
/// Cinematic and cinematic-extended add "much more latency" to the preview this output feeds and "significantly
/// more system memory" (AVCaptureDevice.h) for a 384 px circle.
AVCaptureVideoStabilizationMode TGVideoMessageStabilizationMode(bool connectionSupportsStabilization, bool formatSupportsStandard);

#ifdef __cplusplus
}
#endif
