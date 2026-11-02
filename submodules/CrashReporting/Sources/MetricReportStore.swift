import CryptoKit
import Foundation

/// MetricKit metric and diagnostic reports, kept on the device next to the crash reports so they can be sent from
/// Debug Settings ▸ Send MetricKit Reports. Nothing is uploaded automatically.
///
/// MetricKit hands the same diagnostics over again at every launch (`pastDiagnosticPayloads`), so a report is stored
/// once by content hash. The store keeps the newest `maxFiles` reports and at most `maxBytes` in total.
public final class MetricReportStore {
    public enum Kind: String {
        case metrics
        case diagnostics
    }

    public static let shared = MetricReportStore(directory: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Library/Application Support/CrashReports/MetricKit", isDirectory: true))

    private let directory: URL
    private let maxFiles: Int
    private let maxBytes: Int
    private let queue = DispatchQueue(label: "org.telegram.metric-reports")

    public init(directory: URL, maxFiles: Int = 60, maxBytes: Int = 8 * 1024 * 1024) {
        self.directory = directory
        self.maxFiles = max(1, maxFiles)
        self.maxBytes = max(1, maxBytes)
    }

    /// Stores `json` unless the same report is already stored. Returns whether it was new.
    @discardableResult
    public func store(_ json: Data, kind: Kind, intervalEnd: Date) throws -> Bool {
        return try self.queue.sync {
            let hash = SHA256.hash(data: json).prefix(8).map { String(format: "%02x", $0) }.joined()
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true, attributes: nil)
            var directory = self.directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try directory.setResourceValues(values)

            let existing = try self.storedFiles()
            if existing.contains(where: { $0.url.lastPathComponent.hasSuffix("-\(hash).json") }) {
                return false
            }
            let name = "\(kind.rawValue)-\(Int64(intervalEnd.timeIntervalSince1970))-\(hash).json"
            let url = self.directory.appendingPathComponent(name)
            #if os(iOS)
            try json.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try json.write(to: url, options: .atomic)
            #endif
            try self.prune()
            return true
        }
    }

    /// Stored reports, newest first, as (file name, path).
    public func reports() -> [(name: String, path: String)] {
        return self.queue.sync {
            return ((try? self.storedFiles()) ?? []).map { ($0.url.lastPathComponent, $0.url.path) }
        }
    }

    private func storedFiles() throws -> [(url: URL, date: Int64, size: Int)] {
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(at: self.directory, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        }
        var result: [(url: URL, date: Int64, size: Int)] = []
        for url in urls where url.pathExtension == "json" {
            let parts = url.deletingPathExtension().lastPathComponent.split(separator: "-")
            guard parts.count == 3, let date = Int64(parts[1]) else {
                continue
            }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            result.append((url, date, size))
        }
        return result.sorted {
            if $0.date != $1.date {
                return $0.date > $1.date
            }
            return $0.url.lastPathComponent < $1.url.lastPathComponent
        }
    }

    private func prune() throws {
        var totalBytes = 0
        for (index, file) in try self.storedFiles().enumerated() {
            totalBytes += file.size
            if index >= self.maxFiles || (index > 0 && totalBytes > self.maxBytes) {
                try? FileManager.default.removeItem(at: file.url)
            }
        }
    }
}
