import Foundation
import OSLog

/// The files of the watch's report, built from plain values so they can be tested without a watch.
struct WatchReportInputs: Sendable {
    var created: Date
    var appVersion: String
    var buildNumber: String
    var bundleId: String
    var osVersion: String
    var modelIdentifier: String
    var context: EnergyContext
    var energyText: String
    var logText: String
    var logNote: String
}

enum WatchReportBuilder {
    static func payload(_ inputs: WatchReportInputs) -> WatchReportPayload {
        let info = [
            "App: Nanogram watchOS \(inputs.appVersion) (\(inputs.buildNumber)), \(inputs.bundleId)",
            "OS: \(inputs.osVersion)",
            "Device: \(inputs.modelIdentifier)",
            "State: " + inputs.context.text,
            ""
        ].joined(separator: "\n")
        let files = [
            WatchReportFile(name: "info.txt", text: info),
            WatchReportFile(name: "energy.txt", text: inputs.energyText),
            WatchReportFile(name: "log.txt", text: inputs.logText)
        ]
        let manifest = [
            "Nanogram watch report",
            "Created: \(ISO8601DateFormatter().string(from: inputs.created))",
            "",
            "Parts",
            "- info.txt: device, OS and app build, battery, Low Power Mode and thermal state",
            "- energy.txt: CPU and energy numbers of this launch and per behaviour switch since it last changed",
            "- log.txt: " + inputs.logNote,
            "",
            "Message text, contacts and chat titles are not in these files; phone numbers and emails are masked by the iPhone.",
            ""
        ].joined(separator: "\n")
        return WatchReportPayload(created: inputs.created, files: [WatchReportFile(name: "manifest.txt", text: manifest)] + files)
    }

    /// The app's own log lines of this launch (OSLog keeps nothing of earlier launches for the app to read).
    static func logText(since start: Date, limit: Int = 4000) -> (text: String, note: String) {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else {
            return ("", "the watch's log could not be opened")
        }
        let predicate = NSPredicate(format: "subsystem == %@", Logger.watchSubsystem)
        guard let entries = try? store.getEntries(at: store.position(date: start), matching: predicate) else {
            return ("", "the watch's log could not be read")
        }
        var lines: [String] = []
        let formatter = ISO8601DateFormatter()
        for case let entry as OSLogEntryLog in entries {
            lines.append("\(formatter.string(from: entry.date)) [\(entry.category)] \(entry.composedMessage)")
        }
        let kept = lines.suffix(limit)
        let note = "the watch app's log lines of this launch (\(kept.count) of \(lines.count), newest kept); earlier launches are not readable"
        return (kept.joined(separator: "\n") + "\n", note)
    }
}
