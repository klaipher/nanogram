import Foundation
import Photos

/// Decides when `MediaAssetsContext` registers with the photo library. The registration (and the status
/// query before it) is the first PhotoKit call of a picker open and took 22 ms in `MediaAssetsContext.init`
/// on the main thread. It now happens on the thread that first asks for assets (the picker fetches on a
/// background queue), still before that first fetch, and exactly once per grant.
final class ChangeObserverGate {
    private let lock = NSLock()
    private var registered = false

    init() {
    }

    /// True exactly once: the first time the status allows reading (authorized or limited).
    func shouldRegister(for status: PHAuthorizationStatus) -> Bool {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        if self.registered {
            return false
        }
        switch status {
        case .authorized, .limited:
            self.registered = true
            return true
        default:
            return false
        }
    }

    var isRegistered: Bool {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.registered
    }
}
