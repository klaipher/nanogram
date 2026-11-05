import Foundation
import SwiftSignalKit

/// Runs a cache walker (`TimeBasedCleanup` scan, `AutomaticCacheEviction`) on the schedule `CacheWalkerGate` gives.
public enum CacheWalkerSchedule {
    /// A re-armed run never comes sooner than this after the previous one finished, so a record that could not be
    /// stored cannot turn the schedule into a loop.
    public static let minimumRearmDelay: Double = 60.0 * 60.0

    /// Reads the record, waits (`CacheWalkerGate.nextRunDelay`: the configured delay if due, the rest of the day if
    /// not), runs `run`, and arms the same again once it has completed, so a process that lives for days keeps
    /// enforcing the limits. Disposing the signal stops the schedule. `skipped` is called when the walker is not due
    /// at launch, with the record, for logging. The wait follows the wall clock, also through sleep.
    public static func signal(
        recordSignal: Signal<CacheWalkerRecord?, NoError>,
        fingerprint: String,
        configuredDelay: Double,
        processStartTime: Double = CacheWalkerGate.processStartTime,
        queue: Queue,
        skipped: @escaping (CacheWalkerRecord?) -> Void = { _ in },
        run: Signal<Never, NoError>
    ) -> Signal<Never, NoError> {
        return CacheWalkerSchedule.cycle(recordSignal: recordSignal, fingerprint: fingerprint, configuredDelay: configuredDelay, processStartTime: processStartTime, queue: queue, skipped: skipped, run: run, isRearm: false)
    }

    private static func cycle(
        recordSignal: Signal<CacheWalkerRecord?, NoError>,
        fingerprint: String,
        configuredDelay: Double,
        processStartTime: Double,
        queue: Queue,
        skipped: @escaping (CacheWalkerRecord?) -> Void,
        run: Signal<Never, NoError>,
        isRearm: Bool
    ) -> Signal<Never, NoError> {
        return recordSignal
        |> mapToSignal { record -> Signal<Never, NoError> in
            let now = Date().timeIntervalSince1970
            if !isRearm && !CacheWalkerGate.isDue(record: record, fingerprint: fingerprint, now: now) {
                skipped(record)
            }
            var delay = CacheWalkerGate.nextRunDelay(record: record, fingerprint: fingerprint, now: now, configured: configuredDelay, processStartTime: processStartTime)
            if isRearm {
                delay = max(delay, CacheWalkerSchedule.minimumRearmDelay)
            }
            let next = deferred {
                return CacheWalkerSchedule.cycle(recordSignal: recordSignal, fingerprint: fingerprint, configuredDelay: configuredDelay, processStartTime: processStartTime, queue: queue, skipped: skipped, run: run, isRearm: true)
            }
            return run
            |> suspendAwareDelay(delay, granularity: 600.0, queue: queue)
            |> then(next)
        }
    }
}
