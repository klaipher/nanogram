import Foundation
import OSLog
@preconcurrency import TDShim

/// Decodes TDLib updates on the client's own update queue and hands them to the main thread in
/// batches: one main-queue turn for everything that arrives before the main thread gets to it,
/// instead of one turn per update.
///
/// Order is kept, including against responses. A response resumes its awaiting task through the
/// main queue, so `responseArrived()` (called on the same queue, just before the response's
/// completion runs) closes the open batch: updates TDLib sent after the response go into a new
/// batch queued behind it, as they were when every update had its own turn.
///
/// Update kinds the models do not cover (`.unsupported`: user status, chat actions, unread
/// counters, …) are dropped here, off the main thread.
final class TDUpdateDelivery: @unchecked Sendable {
    private final class Batch {
        var updates: [Update] = []
    }

    private let logger: os.Logger
    private let deliver: @MainActor ([Update]) -> Void
    private let lock = NSLock()
    /// The batch a main-queue turn has been scheduled for and not yet taken.
    private var open: Batch?

    init(logger: os.Logger, deliver: @escaping @MainActor ([Update]) -> Void) {
        self.logger = logger
        self.deliver = deliver
    }

    /// TDLib's update callback (on the client's update queue).
    func receive(_ data: Data, decoder: JSONDecoder) {
        let update: Update
        do {
            update = try decoder.decode(Update.self, from: data)
        } catch {
            logger.warning("update decode failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        if case .unsupported = update { return }

        lock.lock()
        let batch: Batch
        let schedule: Bool
        if let open {
            batch = open
            schedule = false
        } else {
            batch = Batch()
            open = batch
            schedule = true
        }
        batch.updates.append(update)
        lock.unlock()

        guard schedule else { return }
        DispatchQueue.main.async { [self] in
            lock.lock()
            if open === batch { open = nil }
            let updates = batch.updates
            lock.unlock()
            MainActor.assumeIsolated { deliver(updates) }
        }
    }

    /// TDLib's response callback (on the same queue, before the completion runs).
    func responseArrived() {
        lock.lock()
        open = nil
        lock.unlock()
    }

    /// The pair `TDLibClientManager.createClient` takes. Built here, outside any actor: a closure
    /// written inside a `@MainActor` method is main-actor isolated in Swift 6 and traps when TDLib
    /// calls it on its own queue.
    func makeHandlers() -> (update: (Data, TDLibClient) -> Void, response: () -> Void) {
        ({ [self] data, client in receive(data, decoder: client.decoder) }, { [self] in responseArrived() })
    }
}
