import Foundation

final class DeferredAssetRequest<Token> {
    private let lock = NSLock()
    private var token: Token?
    private var isCancelled = false

    func start(request: () -> Token, cancelRequest: (Token) -> Void) {
        lock.lock()
        let cancelled = isCancelled
        lock.unlock()
        if cancelled {
            return
        }
        let newToken = request()
        lock.lock()
        let cancelledMeanwhile = isCancelled
        if !cancelledMeanwhile {
            token = newToken
        }
        lock.unlock()
        if cancelledMeanwhile {
            cancelRequest(newToken)
        }
    }

    func cancel(cancelRequest: (Token) -> Void) {
        lock.lock()
        isCancelled = true
        let current = token
        token = nil
        lock.unlock()
        if let current {
            cancelRequest(current)
        }
    }
}
