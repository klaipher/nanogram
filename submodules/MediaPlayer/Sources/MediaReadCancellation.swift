import Foundation

/// A cancel switch for a thread that blocks on a semaphore while it waits for media data.
///
/// The old dispose actions signalled whatever semaphore the reading thread had published at that moment. A dispose that
/// arrived before the thread published one signalled nothing, and the thread then waited with nobody left to wake it.
/// Here the cancelled flag is set first and checked under the same lock that registers the semaphore, so a cancel
/// either finds the registered semaphore and signals it, or is seen by the reader before it waits.
final class MediaReadCancellation {
    private let lock = NSLock()
    private var cancelled = false
    private var waiting: [ObjectIdentifier: DispatchSemaphore] = [:]

    var isCancelled: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.cancelled
    }

    func cancel() {
        self.lock.lock()
        self.cancelled = true
        let semaphores = Array(self.waiting.values)
        self.lock.unlock()

        for semaphore in semaphores {
            semaphore.signal()
        }
    }

    fileprivate func register(_ semaphore: DispatchSemaphore) -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        if self.cancelled {
            return false
        }
        self.waiting[ObjectIdentifier(semaphore)] = semaphore
        return true
    }

    fileprivate func unregister(_ semaphore: DispatchSemaphore) {
        self.lock.lock()
        self.waiting[ObjectIdentifier(semaphore)] = nil
        self.lock.unlock()
    }
}

/// What a reading thread checks before it blocks: the lifetime of its frame source (cancelled when the source goes
/// away) and the request it is serving right now (cancelled when that request is disposed). `request` is only touched
/// by the reading thread.
final class MediaReadCancellationScope {
    let lifetime: MediaReadCancellation
    var request: MediaReadCancellation?

    init(lifetime: MediaReadCancellation) {
        self.lifetime = lifetime
    }

    var isCancelled: Bool {
        return self.lifetime.isCancelled || self.request?.isCancelled == true
    }

    /// Blocks until `semaphore` is signalled, unless the scope is cancelled before or during the wait. Returns false
    /// when it did not wait because the scope was already cancelled.
    @discardableResult
    func wait(_ semaphore: DispatchSemaphore) -> Bool {
        var tokens: [MediaReadCancellation] = [self.lifetime]
        if let request = self.request {
            tokens.append(request)
        }
        var registered: [MediaReadCancellation] = []
        for token in tokens {
            if token.register(semaphore) {
                registered.append(token)
            } else {
                for other in registered {
                    other.unregister(semaphore)
                }
                return false
            }
        }
        semaphore.wait()
        for token in registered {
            token.unregister(semaphore)
        }
        return true
    }
}
