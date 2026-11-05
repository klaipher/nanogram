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

    /// The delay before a due walker starts: the configured one, and at least until a minute after launch.
    public static func delay(configured: Double, processStartTime: Double = CacheWalkerGate.processStartTime, now: Double = Date().timeIntervalSince1970) -> Double {
        let untilLaunchWindowEnds = processStartTime + CacheWalkerGate.minimumDelayAfterLaunch - now
        if !untilLaunchWindowEnds.isFinite {
            return configured
        }
        return max(configured, untilLaunchWindowEnds, 0.0)
    }
}

/// Decides which cache files need their modification time set to now. A file is touched when it is used so the
/// size-limit cleanup removes the least recently used first. The first touch of a file after launch used to always
/// write (the in-memory dedupe starts empty): hundreds of `utime` metadata writes in the seconds a sticker panel
/// opens. A `stat` is a read, and a file touched in a recent session already has a fresh time.
public enum CacheTouchPolicy {
    /// Must stay well below the one-hour store time of short-lived files (see `RecentFileTouches`).
    public static let skipInterval: Double = 5.0 * 60.0

    public static func needsTouch(modificationTime: Double?, now: Double, interval: Double = CacheTouchPolicy.skipInterval) -> Bool {
        guard let modificationTime, modificationTime.isFinite, now.isFinite else {
            return true
        }
        let age = now - modificationTime
        return age < 0.0 || age >= interval
    }

    /// The subset of `paths` (in order) whose modification time is stale. A path that does not exist is dropped.
    public static func touchNeeded(paths: [String], now: Double, interval: Double = CacheTouchPolicy.skipInterval) -> [String] {
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
            if CacheTouchPolicy.needsTouch(modificationTime: modificationTime, now: now, interval: interval) {
                result.append(path)
            }
        }
        return result
    }
}
