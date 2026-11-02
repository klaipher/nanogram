/// A background task that is ended exactly once, whichever comes first: its own deadline, the system's expiration
/// handler, or an explicit end. `UIApplication.endBackgroundTask` must be called once per begin; the "lock" task the
/// app begins on entering the background was ended by both its 5 s timer and its expiration handler, and never
/// forgot its identifier.
@MainActor
public final class OneShotBackgroundTask<Identifier> {
    private let endTask: (Identifier) -> Void
    private var identifier: Identifier?

    public init(end: @escaping (Identifier) -> Void) {
        self.endTask = end
    }

    /// Starts the task: `begin` begins it with the expiration handler it is given and returns its identifier (nil
    /// when none was granted). A task still held is ended first.
    public func begin(_ begin: (_ expiration: @escaping @MainActor () -> Void) -> Identifier?) {
        self.end()
        self.identifier = begin { [weak self] in
            self?.end()
        }
    }

    /// Whether the task is still held.
    public var isActive: Bool {
        return self.identifier != nil
    }

    /// Ends the task if it is still held.
    public func end() {
        guard let identifier = self.identifier else {
            return
        }
        self.identifier = nil
        self.endTask(identifier)
    }
}
