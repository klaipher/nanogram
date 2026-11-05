import Foundation

/// Keys of the walkers in the storage index.
public enum CacheWalkerName {
    public static let timeBasedCleanup = "timeBasedCleanup"
    public static let automaticCacheEviction = "automaticCacheEviction"
}

/// What the last run of a cache walker looked like. Kept in the storage index of the account (`StorageBox`), so it
/// costs no server traffic and survives relaunches.
public struct CacheWalkerRecord: Codable, Equatable {
    public var completedAt: Double
    /// Identifies the limits the run enforced. A walker whose limits changed is due again at once.
    public var fingerprint: String

    public init(completedAt: Double, fingerprint: String) {
        self.completedAt = completedAt
        self.fingerprint = fingerprint
    }
}

/// When the cache walkers (the time-based cleanup scan and the automatic cache eviction) may run. Both `stat` every
/// cached file, which cost seconds of CPU at every launch. They run at most once a day per account, when their
/// limits change, or when asked explicitly, and never in the first minute after launch.
public enum CacheWalkerGate {
    public static let minimumInterval: Double = 24.0 * 60.0 * 60.0
    public static let minimumDelayAfterLaunch: Double = 60.0

    /// Unix time at which this process started; the time of first use if the system does not tell.
    public static let processStartTime: Double = {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let result = mib.withUnsafeMutableBufferPointer { pointer -> Int32 in
            return sysctl(pointer.baseAddress, 4, &info, &size, nil, 0)
        }
        let fallback = Date().timeIntervalSince1970
        if result == 0 {
            let start = info.kp_proc.p_un.__p_starttime
            let value = Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000.0
            if value.isFinite && value > 0.0 && value <= fallback {
                return value
            }
        }
        return fallback
    }()

    public static func isDue(record: CacheWalkerRecord?, fingerprint: String, now: Double) -> Bool {
        guard let record else {
            return true
        }
        if record.fingerprint != fingerprint {
            return true
        }
        let elapsed = now - record.completedAt
        // A clock set backwards, or an odd value, must not block the walker for good.
        if !elapsed.isFinite || elapsed < 0.0 {
            return true
        }
        return elapsed >= CacheWalkerGate.minimumInterval
    }

    /// The limits a time-based cleanup scan enforces, as the scan applies them: without a size limit short-lived
    /// files are kept as long as the others (`TimeBasedCleanupImpl.makeScan`). The gate and the record it is compared
    /// with both use this, so the same settings always give the same text.
    public static func timeBasedCleanupFingerprint(general: Int32, shortLived: Int32, gigabytesLimit: Int32) -> String {
        let effectiveShortLived = gigabytesLimit == Int32.max ? Int32.max : shortLived
        return "\(general),\(effectiveShortLived),\(gigabytesLimit)"
    }

    /// The delay before a due walker starts: the configured one, and at least until a minute after launch.
    public static func delay(configured: Double, processStartTime: Double = CacheWalkerGate.processStartTime, now: Double = Date().timeIntervalSince1970) -> Double {
        let untilLaunchWindowEnds = processStartTime + CacheWalkerGate.minimumDelayAfterLaunch - now
        if !untilLaunchWindowEnds.isFinite {
            return configured
        }
        return max(configured, untilLaunchWindowEnds, 0.0)
    }

    /// How long to wait before the next scheduled run. A walker that is due waits the configured delay (and the
    /// launch window). One that is not due waits until it is, a day after its last run, instead of giving up: a
    /// process that stays alive for days (macOS) would otherwise skip at launch and never enforce the limits again.
    public static func nextRunDelay(record: CacheWalkerRecord?, fingerprint: String, now: Double, configured: Double, processStartTime: Double = CacheWalkerGate.processStartTime) -> Double {
        if let record, !CacheWalkerGate.isDue(record: record, fingerprint: fingerprint, now: now) {
            let untilDue = record.completedAt + CacheWalkerGate.minimumInterval - now
            return CacheWalkerGate.delay(configured: max(untilDue, 0.0), processStartTime: processStartTime, now: now)
        }
        return CacheWalkerGate.delay(configured: configured, processStartTime: processStartTime, now: now)
    }
}

/// Decides which cache files need their modification time set to now. A file is touched when it is used so the
/// size-limit cleanup removes the least recently used first. The first touch of a file after launch used to always
/// write (the in-memory dedupe starts empty): hundreds of `utime` metadata writes in the seconds a sticker panel
/// opens. A `stat` is a read, and a file touched in a recent session already has a fresh enough time.
public enum CacheTouchPolicy {
    /// Short-lived files (`short-cache`) are removed one hour after their last use (see `RecentFileTouches`), so
    /// their time may only be minutes stale.
    public static let shortLivedSkipInterval: Double = 5.0 * 60.0
    /// Every other cache file is removed a day after its last use at the earliest (the shortest "keep media"
    /// choice, and the automatic cache eviction reads the same time), and the size limit removes the least
    /// recently used first. A time up to an hour stale moves either by under 5 %, and an hour covers the usual
    /// relaunch (the system ends the app in the background and the person opens it again).
    public static let skipInterval: Double = 60.0 * 60.0
    /// The longest a general file's time may be stale, whatever the keep time: the size limit orders by this time,
    /// and a day is the shortest "keep media" choice.
    public static let maximumGeneralInterval: Double = 24.0 * 60.0 * 60.0

    /// The keep time the touch interval follows: the shortest of the general keep time and the per-chat ones
    /// (categories, stories, exceptions), because `AutomaticCacheEviction` removes a chat's media by the same
    /// modification time. `nil` until both are known.
    public static func keepTimeForTouches(general: Int32?, shortestPerChat: Int32?) -> Int32? {
        guard let general, let shortestPerChat else {
            return nil
        }
        return min(general, shortestPerChat)
    }

    /// How stale the time of a general cache file may be, for the keep time in effect (`nil` until it is known).
    /// A twentieth of the keep time moves a removal by under 5 %; at least `skipInterval`, which covers the usual
    /// relaunch, and at most a day. A file used on an earlier day of the same week is not rewritten at every launch.
    public static func generalInterval(generalMaxStoreTime: Int32?) -> Double {
        guard let generalMaxStoreTime else {
            return CacheTouchPolicy.skipInterval
        }
        if generalMaxStoreTime == Int32.max {
            return CacheTouchPolicy.maximumGeneralInterval
        }
        let twentieth = Double(max(generalMaxStoreTime, 0)) / 20.0
        return min(CacheTouchPolicy.maximumGeneralInterval, max(CacheTouchPolicy.skipInterval, twentieth))
    }

    public static func needsTouch(modificationTime: Double?, now: Double, interval: Double) -> Bool {
        guard let modificationTime, modificationTime.isFinite, now.isFinite else {
            return true
        }
        let age = now - modificationTime
        return age < 0.0 || age >= interval
    }

    /// How stale the time of the file at `path` may be: the short interval inside a short-lived folder.
    public static func interval(forPath path: String, shortLivedPaths: [String], generalInterval: Double = CacheTouchPolicy.skipInterval) -> Double {
        for directory in shortLivedPaths {
            if path.hasPrefix(directory.hasSuffix("/") ? directory : directory + "/") {
                return CacheTouchPolicy.shortLivedSkipInterval
            }
        }
        return generalInterval
    }

    /// The subset of `paths` (in order) whose modification time is stale. A path that does not exist is dropped.
    public static func touchNeeded(paths: [String], shortLivedPaths: [String], now: Double, generalInterval: Double = CacheTouchPolicy.skipInterval) -> [String] {
        var result: [String] = []
        result.reserveCapacity(paths.count)
        for path in paths {
            var value = stat()
            if stat(path, &value) != 0 {
                if errno == ENOENT {
                    continue
                }
                result.append(path)
                continue
            }
            let modificationTime = Double(value.st_mtimespec.tv_sec) + Double(value.st_mtimespec.tv_nsec) / 1_000_000_000.0
            let interval = CacheTouchPolicy.interval(forPath: path, shortLivedPaths: shortLivedPaths, generalInterval: generalInterval)
            if CacheTouchPolicy.needsTouch(modificationTime: modificationTime, now: now, interval: interval) {
                result.append(path)
            }
        }
        return result
    }
}
