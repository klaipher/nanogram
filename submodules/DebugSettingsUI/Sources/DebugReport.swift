import Foundation
import ZipArchive

// The tester's one "Send Report": every diagnostic the app keeps, in one zip with a README that lists each part.
// This file holds the parts of that report that do not touch the app (what is chosen under the size cap, the
// README, the redaction, the zip); `DebugReportSources.swift` collects the files.

/// The parts of a report, in the order they are kept when the size cap is reached.
enum DebugReportSection: CaseIterable, Equatable {
    case info
    case crashes
    case metricKit
    case criticalLogs
    case appLogs
    case notificationLogs
    case shareLogs
    case otherExtensionLogs
    case callLogs
    case groupCallLogs
    case cpuProfiles

    var folder: String {
        switch self {
        case .info: return "info"
        case .crashes: return "crashes"
        case .metricKit: return "metrickit"
        case .criticalLogs: return "critical-logs"
        case .appLogs: return "logs/app"
        case .notificationLogs: return "logs/notification-extension"
        case .shareLogs: return "logs/share-extension"
        case .otherExtensionLogs: return "logs/other-extensions"
        case .callLogs: return "calls"
        case .groupCallLogs: return "group-calls"
        case .cpuProfiles: return "cpu-profiles"
        }
    }

    var title: String {
        switch self {
        case .info: return "Device, app and experiment details"
        case .crashes: return "Crash reports"
        case .metricKit: return "MetricKit reports (hangs, CPU, energy, disk writes, memory)"
        case .criticalLogs: return "Critical logs (short logs of the app and the notification extension)"
        case .appLogs: return "Main app logs"
        case .notificationLogs: return "Notification extension logs"
        case .shareLogs: return "Share extension logs"
        case .otherExtensionLogs: return "Other extension logs (widgets, Siri, broadcast, notification content)"
        case .callLogs: return "Call logs (newest calls)"
        case .groupCallLogs: return "Group call logs"
        case .cpuProfiles: return "CPU profiles"
        }
    }
}

/// How a file is written into the report.
enum DebugReportTreatment: Equatable {
    /// A text log: the newest part is kept when it is over the per-file size, and phone numbers and emails are masked.
    case redactedText
    /// Copied as it is (JSON reports, binary short logs); left out when over the per-file size.
    case unchanged
}

/// One file or text that can go into the report.
struct DebugReportSource: Equatable {
    var section: DebugReportSection
    var name: String
    /// The file to read; nil when `text` holds the content.
    var path: String?
    var text: String?
    var treatment: DebugReportTreatment
    var modified: Date
    var size: Int64

    init(section: DebugReportSection, name: String, path: String, treatment: DebugReportTreatment, modified: Date, size: Int64) {
        self.section = section
        self.name = name
        self.path = path
        self.text = nil
        self.treatment = treatment
        self.modified = modified
        self.size = size
    }

    init(section: DebugReportSection, name: String, text: String, modified: Date) {
        self.section = section
        self.name = name
        self.path = nil
        self.text = text
        self.treatment = .redactedText
        self.modified = modified
        self.size = Int64(text.utf8.count)
    }
}

struct DebugReportLimits: Equatable {
    var totalBytes: Int64 = 40 * 1024 * 1024
    var sectionBytes: Int64 = 16 * 1024 * 1024
    var fileBytes: Int64 = 8 * 1024 * 1024
}

struct DebugReportEntry: Equatable {
    var source: DebugReportSource
    /// The path inside the zip.
    var entryName: String
    /// The bytes this entry takes before masking; less than the source size when only its newest part is kept.
    var bytes: Int64
    var isCut: Bool
}

struct DebugReportPlan: Equatable {
    var entries: [DebugReportEntry]
    /// Left out because they did not fit under the caps.
    var omitted: [DebugReportSource]
}

/// Picks what goes into the report: sections in their order, the newest file of each first, until a cap is reached.
/// The info section is always kept (it is a few kilobytes).
func debugReportPlan(sources: [DebugReportSource], limits: DebugReportLimits = DebugReportLimits()) -> DebugReportPlan {
    var entries: [DebugReportEntry] = []
    var omitted: [DebugReportSource] = []
    var total: Int64 = 0
    var usedNames = Set<String>()
    for section in DebugReportSection.allCases {
        let candidates = sources.filter { $0.section == section }.sorted { lhs, rhs in
            if lhs.modified != rhs.modified {
                return lhs.modified > rhs.modified
            }
            return lhs.name < rhs.name
        }
        var sectionTotal: Int64 = 0
        for source in candidates {
            var bytes = source.size
            var isCut = false
            if bytes > limits.fileBytes {
                if source.treatment == .unchanged {
                    omitted.append(source)
                    continue
                }
                bytes = limits.fileBytes
                isCut = true
            }
            if section != .info && (total + bytes > limits.totalBytes || sectionTotal + bytes > limits.sectionBytes) {
                omitted.append(source)
                continue
            }
            total += bytes
            sectionTotal += bytes
            entries.append(DebugReportEntry(source: source, entryName: debugReportEntryName(source, used: &usedNames), bytes: bytes, isCut: isCut))
        }
    }
    return DebugReportPlan(entries: entries, omitted: omitted)
}

private func debugReportEntryName(_ source: DebugReportSource, used: inout Set<String>) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
    var leaf = (source.name as NSString).lastPathComponent.unicodeScalars.map { allowed.contains($0) ? String($0) : "_" }.joined()
    if leaf.isEmpty || leaf == "." || leaf == ".." {
        leaf = "file"
    }
    var name = source.section.folder + "/" + leaf
    var counter = 2
    while used.contains(name) {
        name = source.section.folder + "/\(counter)-" + leaf
        counter += 1
    }
    used.insert(name)
    return name
}

/// The line shown before sending: what the report holds and what it never does.
let debugReportPrivacyNote = "Includes device and app details, experiment numbers, app and extension logs, call logs, and crash and MetricKit reports. No message text, contacts or contact lists; phone numbers and emails are masked."

/// The README at the top of the zip.
func debugReportManifest(infoLines: [String], plan: DebugReportPlan, created: Date, limits: DebugReportLimits = DebugReportLimits()) -> String {
    var lines = ["Nanogram report", ""]
    let formatter = ISO8601DateFormatter()
    lines.append("Created: \(formatter.string(from: created))")
    lines.append(contentsOf: infoLines)
    lines.append("")
    lines.append(debugReportPrivacyNote)
    lines.append("Phone numbers (+...) and email addresses in the text files are replaced by [phone] and [email]. Each log file is cut to its newest \(debugReportSizeText(limits.fileBytes)), the report to \(debugReportSizeText(limits.totalBytes)).")
    lines.append("")
    lines.append("Parts")
    for section in DebugReportSection.allCases {
        let entries = plan.entries.filter { $0.source.section == section }
        let omitted = plan.omitted.filter { $0.section == section }
        var summary = "\(section.title) [\(section.folder)/]: "
        if entries.isEmpty && omitted.isEmpty {
            summary += "none on this device"
        } else {
            summary += "\(entries.count) file\(entries.count == 1 ? "" : "s"), \(debugReportSizeText(entries.reduce(0) { $0 + $1.bytes }))"
            if !omitted.isEmpty {
                summary += ", \(omitted.count) older or larger left out"
            }
        }
        lines.append("- " + summary)
        for entry in entries {
            lines.append("    \(entry.entryName)" + (entry.isCut ? " (newest \(debugReportSizeText(entry.bytes)) of \(debugReportSizeText(entry.source.size)))" : ""))
        }
        for source in omitted {
            lines.append("    left out: \(source.name) (\(debugReportSizeText(source.size)))")
        }
    }
    lines.append("")
    return lines.joined(separator: "\n")
}

func debugReportSizeText(_ bytes: Int64) -> String {
    if bytes >= 1024 * 1024 {
        return String(format: "%.1f MB", Double(bytes) / 1048576.0)
    }
    if bytes >= 1024 {
        return String(format: "%.1f KB", Double(bytes) / 1024.0)
    }
    return "\(bytes) B"
}

private let debugReportPhonePattern = try? NSRegularExpression(pattern: "\\+\\d[\\d \\-().]{6,}\\d", options: [])
private let debugReportEmailPattern = try? NSRegularExpression(pattern: "[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}", options: [.caseInsensitive])

/// Masks phone numbers written with a leading "+" and email addresses. The logs already leave out message text and
/// contacts (Remove Sensitive Data); this is the second net for what a log line might still carry.
func debugReportRedacted(_ text: String) -> String {
    var result = text
    for (pattern, replacement) in [(debugReportEmailPattern, "[email]"), (debugReportPhonePattern, "[phone]")] {
        guard let pattern else {
            continue
        }
        result = pattern.stringByReplacingMatches(in: result, options: [], range: NSRange(location: 0, length: (result as NSString).length), withTemplate: replacement)
    }
    return result
}

/// The newest `limit` bytes of a text file, starting at a line start, with a marker line when something was cut.
func debugReportTail(of url: URL, limit: Int64) -> Data? {
    guard let handle = try? FileHandle(forReadingFrom: url) else {
        return nil
    }
    defer {
        try? handle.close()
    }
    guard let size = try? handle.seekToEnd() else {
        return nil
    }
    if Int64(size) <= limit {
        try? handle.seek(toOffset: 0)
        return try? handle.readToEnd() ?? Data()
    }
    try? handle.seek(toOffset: size - UInt64(limit))
    guard var data = try? handle.readToEnd() else {
        return nil
    }
    if let lineFeed = data.firstIndex(of: 0x0A) {
        data = data.subdata(in: data.index(after: lineFeed) ..< data.endIndex)
    }
    var result = Data("[earlier lines cut: only the newest \(debugReportSizeText(limit)) of this file are kept]\n".utf8)
    result.append(data)
    return result
}

/// Writes the plan's files and the README under "<baseName>/" and zips them into "<baseName>.zip" in `directory`.
func debugReportArchive(plan: DebugReportPlan, manifest: String, baseName: String, in directory: URL) -> DebugLogExportFile? {
    let staging = directory.appendingPathComponent(baseName, isDirectory: true)
    let fileManager = FileManager.default
    defer {
        let _ = try? fileManager.removeItem(at: staging)
    }
    do {
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data(manifest.utf8).write(to: staging.appendingPathComponent("README.txt"))
        for entry in plan.entries {
            let target = staging.appendingPathComponent(entry.entryName)
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let source = entry.source
            if let text = source.text {
                try Data(debugReportRedacted(text).utf8).write(to: target)
            } else if let path = source.path {
                let url = URL(fileURLWithPath: path)
                switch source.treatment {
                case .redactedText:
                    guard let data = debugReportTail(of: url, limit: entry.bytes) else {
                        continue
                    }
                    try Data(debugReportRedacted(String(decoding: data, as: UTF8.self)).utf8).write(to: target)
                case .unchanged:
                    try fileManager.copyItem(at: url, to: target)
                }
            }
        }
    } catch {
        return nil
    }
    let archive = directory.appendingPathComponent("\(baseName).zip")
    guard SSZipArchive.createZipFile(atPath: archive.path, withContentsOfDirectory: staging.path, keepParentDirectory: true) else {
        return nil
    }
    return DebugLogExportFile(name: archive.lastPathComponent, path: archive.path, mimeType: "application/zip")
}
