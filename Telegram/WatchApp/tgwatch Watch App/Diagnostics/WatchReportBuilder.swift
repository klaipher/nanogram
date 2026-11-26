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
    var journalText: String
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
            WatchReportFile(name: "log.txt", text: inputs.logText),
            WatchReportFile(name: "journal.txt", text: inputs.journalText)
        ]
        let manifest = [
            "Nanogram watch report",
            "Created: \(ISO8601DateFormatter().string(from: inputs.created))",
            "",
            "Parts",
            "- info.txt: device, OS and app build, battery, Low Power Mode and thermal state",
            "- energy.txt: CPU and energy numbers of this launch and per behaviour switch since it last changed",
            "- log.txt: " + inputs.logNote,
            "- journal.txt: the app's own list of events (launches, sign-in state, background refreshes, report copies) of this and earlier launches, up to \(Int(WatchEventJournal.maximumAge / 86_400)) days, oldest first",
            "",
            "Message text, contacts and chat titles are not in these files; phone numbers and emails are masked by the iPhone.",
            ""
        ].joined(separator: "\n")
        return WatchReportPayload(created: inputs.created, files: [WatchReportFile(name: "manifest.txt", text: manifest)] + files)
    }

    /// The app's own log lines of this launch (OSLog keeps nothing of earlier launches for the app to read, and on the
    /// watch it drops this launch's lines too after a while; journal.txt covers that).
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
        let note = logNote(kept: kept.count, total: lines.count, launch: start, now: Date())
        return (kept.joined(separator: "\n") + "\n", note)
    }

    /// The manifest's line for log.txt. An empty read says so plainly: watchOS had dropped every line of a 20 h launch
    /// before it was reported, and a bare "0 of 0" read like a broken report.
    static func logNote(kept: Int, total: Int, launch: Date, now: Date) -> String {
        guard total > 0 else {
            let hours = max(0, now.timeIntervalSince(launch)) / 3600
            let age = String(format: "%.1f", hours)
            return "the watch app's log lines of this launch: watchOS kept none of them (the launch began \(age) h ago); journal.txt lists the app's own events"
        }
        return "the watch app's log lines of this launch (\(kept) of \(total), newest kept); earlier launches are not readable here, journal.txt lists their events"
    }
}
