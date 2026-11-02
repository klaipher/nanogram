import Foundation

let accountViewTrackerThrottleRetention: Int32 = 11 * 60 * 60

func prunedAccountViewTrackerThrottleRecords<Key: Hashable>(_ records: [Key: Int32], now: Int32) -> [Key: Int32] {
    let cutoff = now - accountViewTrackerThrottleRetention
    return records.filter { $0.value >= cutoff }
}
