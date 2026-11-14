import Foundation

/// Where the watch part of the report comes from.
enum WatchReportChoice: Equatable {
    /// Fresh from the watch over sendMessage.
    case live(WatchReportPayload)
    /// The last copy the watch transferred in the background.
    case stored(WatchReportPayload)
    case none
}

/// Why the watch part is what it is.
enum WatchLinkState: Equatable {
    case noPairedWatch
    case appNotInstalled
    case reachable
    case unreachable
    case unreachableNoCopy
}

func watchReportChoose(live: WatchReportPayload?, stored: WatchReportPayload?) -> WatchReportChoice {
    if let live {
        return .live(live)
    }
    if let stored {
        return .stored(stored)
    }
    return .none
}

/// One line of the iPhone report's README about the watch.
func watchReportStatusLine(_ choice: WatchReportChoice, link: WatchLinkState) -> String {
    let formatter = ISO8601DateFormatter()
    switch choice {
    case let .live(payload):
        return "Apple Watch: report received from the watch now (made \(formatter.string(from: payload.created)))."
    case let .stored(payload):
        return "Apple Watch: not reachable now, so the last copy the watch transferred is used (made \(formatter.string(from: payload.created)))."
    case .none:
        switch link {
        case .noPairedWatch:
            return "Apple Watch: no paired Apple Watch, so the report has no watch part."
        case .appNotInstalled:
            return "Apple Watch: the Nanogram watch app is not installed on the paired watch, so the report has no watch part."
        case .unreachableNoCopy, .unreachable, .reachable:
            return "Apple Watch: the watch is not reachable and has not transferred a report yet, so the report has no watch part. Open Nanogram on the watch once and send the report again."
        }
    }
}

/// The last report the watch transferred, kept in one file; an older one never replaces a newer one.
final class WatchReportStore: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()

    init(directory: URL) {
        self.url = directory.appendingPathComponent("latest-watch-report.json")
    }

    func load() -> WatchReportPayload? {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        guard let data = try? Data(contentsOf: self.url) else {
            return nil
        }
        return WatchReportPayload.decode(data)
    }

    /// Keeps `data` when it decodes and is not older than what is stored.
    @discardableResult
    func save(_ data: Data) -> Bool {
        guard let payload = WatchReportPayload.decode(data) else {
            return false
        }
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        if let existing = try? Data(contentsOf: self.url), let stored = WatchReportPayload.decode(existing), stored.created > payload.created {
            return false
        }
        do {
            try FileManager.default.createDirectory(at: self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: self.url, options: .atomic)
        } catch {
            return false
        }
        return true
    }
}
