import Foundation

/// Which camera the capturer of a call is on, as the call object believes it. A flip asks the capturer for the camera
/// that is not the believed one, so the belief has to follow every capturer that appears or goes away: a new capturer
/// starts on the front camera, and a flip while there is no capturer changes nothing.
struct CameraFacingTracker: Equatable {
    private(set) var hasCamera = false
    private(set) var isFront = true
    
    mutating func cameraStarted(isFront: Bool = true) {
        self.hasCamera = true
        self.isFront = isFront
    }
    
    mutating func cameraStopped() {
        self.hasCamera = false
        self.isFront = true
    }
    
    /// The camera to switch the capturer to, or nil when there is no camera to flip.
    mutating func flip() -> Bool? {
        if !self.hasCamera {
            return nil
        }
        self.isFront = !self.isFront
        return self.isFront
    }
}
