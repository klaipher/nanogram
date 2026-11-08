import Foundation

/// Decides whether a poll that has just become visible needs its results fetched (`messages.getPollResults`).
///
/// Log of 2026-11-07: 359 `getPollResults` for 45 messages, up to 19 for one poll, because every chat
/// open and every scroll that brings a poll back on screen fetched it at once. A poll fetched less than
/// `window` seconds ago whose stored copy has not changed since the fetch cannot have a newer result
/// that the next fetch would tell us about sooner than the regular refresh already does, so that fetch
/// is skipped. Pure: the clock is a parameter, nothing is shared.
///
/// - A changed stored poll (the user voted or retracted, an update arrived, the poll closed) fetches.
/// - `forget` (an explicit user action: voting, adding or deleting an option, opening the voters list)
///   fetches at once.
/// - Only a fetch that was actually sent is recorded.
struct PollFetchThrottle<Key: Hashable, Fingerprint: Equatable> {
    private struct Record {
        let fingerprint: Fingerprint
        let time: Double
    }

    let window: Double
    private var records: [Key: Record] = [:]

    init(window: Double) {
        self.window = window
    }

    var recordCount: Int {
        return self.records.count
    }

    func shouldFetch(key: Key, fingerprint: Fingerprint, now: Double) -> Bool {
        guard let record = self.records[key] else {
            return true
        }
        if now < record.time || now - record.time >= self.window {
            return true
        }
        return record.fingerprint != fingerprint
    }

    mutating func recordFetch(key: Key, fingerprint: Fingerprint, now: Double) {
        self.records[key] = Record(fingerprint: fingerprint, time: now)
        if self.records.count > 256 {
            let window = self.window
            self.records = self.records.filter { now >= $0.value.time && now - $0.value.time < window }
        }
    }

    mutating func forget(key: Key) {
        self.records[key] = nil
    }
}
