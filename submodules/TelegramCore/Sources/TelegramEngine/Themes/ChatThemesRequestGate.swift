import Foundation

/// Keeps `account.getChatThemes` from going out once per chat open with the same hash: a request for a hash is skipped
/// while an earlier one for it is in flight or was made less than `timeToLive` ago. The request itself is unchanged; a
/// forced update bypasses the gate. Thread safe.
final class ChatThemesRequestGate {
    static let timeToLive: Double = 10.0 * 60.0
    static let shared = ChatThemesRequestGate()

    private let lock = NSLock()
    private var lastRequestTime: [Int64: Double] = [:]

    init() {
    }

    /// Whether a request with this hash should go out now. When it should, the request is recorded as in flight.
    func shouldRequest(hash: Int64, now: Double) -> Bool {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        if let last = self.lastRequestTime[hash], now - last >= 0.0, now - last < ChatThemesRequestGate.timeToLive {
            return false
        }
        // Only one hash is current; older ones are of no use.
        self.lastRequestTime.removeAll()
        self.lastRequestTime[hash] = now
        return true
    }

    /// The request got no answer (frozen account): the next open may try again.
    func forget(hash: Int64) {
        self.lock.lock()
        self.lastRequestTime.removeValue(forKey: hash)
        self.lock.unlock()
    }

    /// The server sent a new list: its hash counts as just checked.
    func noteFresh(hash: Int64, now: Double) {
        self.lock.lock()
        self.lastRequestTime.removeAll()
        self.lastRequestTime[hash] = now
        self.lock.unlock()
    }
}
