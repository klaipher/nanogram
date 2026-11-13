import Foundation

/// Runs a view's heavy one-time setup after the current layout pass instead of inside its initializer (the coin
/// scene load and first render blocked the main thread for 350 to 490 ms while the Premium screen was being presented).
/// The work runs once however often it is requested, and not at all after `cancel()`.
final class DeferredSetup {
    private let schedule: (@escaping () -> Void) -> Void
    private let work: () -> Void
    private var requested = false
    private var cancelled = false
    private(set) var didRun = false
    
    init(schedule: @escaping (@escaping () -> Void) -> Void = { block in DispatchQueue.main.async(execute: block) }, work: @escaping () -> Void) {
        self.schedule = schedule
        self.work = work
    }
    
    func request() {
        guard !self.requested else {
            return
        }
        self.requested = true
        self.schedule { [weak self] in
            guard let self, !self.cancelled, !self.didRun else {
                return
            }
            self.didRun = true
            self.work()
        }
    }
    
    func cancel() {
        self.cancelled = true
    }
}
