/// Takes a report at fixed times after each entry into the background (5 s and 60 s by default), only while the
/// diagnostic is enabled (the app enables it with "Log to File"), and not once the app returned to the foreground.
/// The first shows what the app holds while its background time runs; the second, taken after the usual background
/// task has ended, shows what is left, and arrives late (on resume) if the process was suspended in between.
@MainActor
public final class BackgroundDiagnosticsScheduler {
    public static let defaultDelays: [Double] = [5.0, 60.0]

    private let delays: [Double]
    private let now: () -> Double
    private let schedule: (_ delay: Double, _ block: @escaping @MainActor () -> Void) -> Void
    private var generation = 0

    /// `now` is a wall clock in seconds; `schedule` runs a block on the main thread after a delay.
    public init(delays: [Double] = BackgroundDiagnosticsScheduler.defaultDelays, now: @escaping () -> Double, schedule: @escaping (_ delay: Double, _ block: @escaping @MainActor () -> Void) -> Void) {
        self.delays = delays
        self.now = now
        self.schedule = schedule
    }

    /// `report` gets the seconds since this call and logs what it collects.
    public func didEnterBackground(isEnabled: Bool, report: @escaping @MainActor (_ secondsInBackground: Double) -> Void) {
        self.generation += 1
        guard isEnabled else {
            return
        }
        let generation = self.generation
        let start = self.now()
        for delay in self.delays {
            self.schedule(delay) { [weak self] in
                guard let self, self.generation == generation else {
                    return
                }
                report(self.now() - start)
            }
        }
    }

    public func willEnterForeground() {
        self.generation += 1
    }
}
