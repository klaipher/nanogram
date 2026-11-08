import Foundation

/// Adds up the WAL frames each Postbox transaction call site made SQLite append, so the disk-write ledger's
/// `sqlite.wal.*` line can be traced back to the code that caused it. A transaction that appended nothing (reads) is
/// not counted. It says when to log: at most every ten minutes, and only when something moved, with the call sites
/// that appended the most frames since the previous line.
struct TransactionWriteAttribution: Equatable {
    static let logInterval: Double = 600.0
    static let maxReportedSites = 6

    struct Site: Equatable {
        var commits: Int = 0
        var frames: Int = 0
        var maxFrames: Int = 0
    }

    private(set) var sites: [String: Site] = [:]
    private var lastLogTime: Double?
    private(set) var totalCommits: Int = 0
    private(set) var totalFrames: Int = 0

    /// A single transaction that appended this many bytes of WAL is logged at once with its call site, not in the
    /// ten-minute summary (a process killed or suspended soon after would never log that).
    static let largeCommitBytes = 16 * 1024 * 1024

    static func largeCommitLine(site: String, frames: Int, frameBytes: Int, thresholdBytes: Int = TransactionWriteAttribution.largeCommitBytes) -> String? {
        let bytes = frames * frameBytes
        if frames <= 0 || bytes < thresholdBytes {
            return nil
        }
        return "Postbox large transaction: \(site) appended \(frames) frames to the WAL (\(String(format: "%.1f", Double(bytes) / 1048576.0)) MB)"
    }

    static func siteName(file: String, line: Int) -> String {
        let name = file.split(separator: "/").last.map(String.init) ?? file
        return "\(name):\(line)"
    }

    mutating func note(site: String, frames: Int) {
        if frames <= 0 {
            return
        }
        var entry = self.sites[site] ?? Site()
        entry.commits += 1
        entry.frames += frames
        entry.maxFrames = max(entry.maxFrames, frames)
        self.sites[site] = entry
        self.totalCommits += 1
        self.totalFrames += frames
    }

    mutating func takeLogLine(now: Double) -> String? {
        if self.sites.isEmpty {
            return nil
        }
        if let lastLogTime = self.lastLogTime {
            let elapsed = now - lastLogTime
            if elapsed >= 0.0 && elapsed < TransactionWriteAttribution.logInterval {
                return nil
            }
        }
        let ranked = self.sites.sorted { lhs, rhs in
            if lhs.value.frames != rhs.value.frames {
                return lhs.value.frames > rhs.value.frames
            }
            return lhs.key < rhs.key
        }
        var parts: [String] = []
        for (name, site) in ranked.prefix(TransactionWriteAttribution.maxReportedSites) {
            parts.append("\(name) \(site.frames) frames in \(site.commits) commits (max \(site.maxFrames))")
        }
        let others = ranked.dropFirst(TransactionWriteAttribution.maxReportedSites).reduce(0) { $0 + $1.value.frames }
        if others > 0 {
            parts.append("others \(others) frames")
        }
        let line = "Postbox WAL writes by transaction: \(self.totalFrames) frames in \(self.totalCommits) commits; \(parts.joined(separator: ", "))"
        self.sites.removeAll()
        self.totalCommits = 0
        self.totalFrames = 0
        self.lastLogTime = now
        return line
    }
}
