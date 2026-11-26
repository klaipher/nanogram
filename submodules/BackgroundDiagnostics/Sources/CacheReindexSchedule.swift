/// When the app reindexes the media cache (`Account.cleanupTasks`: every media message is read again, 1000 per
/// transaction, about 140 transactions of 30-190 ms on a large account).
///
/// Two paths run it: the launch check in `didFinishLaunching`, and the background processing task (`<bundle>.cleanup`,
/// on external power). Both read and write the time of the last finished run under `timestampKey`, so a scan the
/// background task finished during the night keeps the launch from repeating it hours later.
public enum CacheReindexSchedule {
    /// UserDefaults key for the last reindex, `Int` seconds of `CFAbsoluteTimeGetCurrent()` stored as an `NSNumber`.
    /// The same key upstream uses, so existing installs keep their value.
    public static let timestampKey = "TelegramCacheIndexTimestamp_v2"

    /// A new reindex is due once this many seconds have passed since the last one.
    public static let minimumInterval = 2 * 24 * 60 * 60

    /// Whether the launch should reindex: never indexed, or the last reindex is more than `minimumInterval` old.
    /// `now` and `lastIndexTimestamp` are `Int` seconds of `CFAbsoluteTimeGetCurrent()`.
    public static func isDue(lastIndexTimestamp: Int?, now: Int) -> Bool {
        guard let lastIndexTimestamp else {
            return true
        }
        let (threshold, overflow) = now.subtractingReportingOverflow(self.minimumInterval)
        if overflow {
            return false
        }
        return lastIndexTimestamp < threshold
    }
}
