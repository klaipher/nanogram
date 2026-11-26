import Foundation
import UIKit
import SwiftSignalKit
import Display
import TelegramCore
import AccountContext
import CrashReporting
import MediaCapabilities
import DiskWriteAccounting
import TelegramVoip
import EnergyNumbers
import WatchReport
import InAppPurchaseManager

/// What the report's info file says about the device and the app.
struct DebugReportInfo: Equatable {
    var appVersion: String
    var buildNumber: String
    var bundleId: String
    var osVersion: String
    var deviceModelIdentifier: String
    var deviceChip: String
    var isMainApp: Bool
    var hasAccount: Bool
    var logToFile: Bool
    var redactSensitiveData: Bool
    var lowPowerMode: Bool
    var thermalState: String
    var localeIdentifier: String
    var experimentsReport: String
    var isStoreBuild: Bool = StorePurchasePolicy.current.isStoreBuild
}

func debugReportInfoLines(_ info: DebugReportInfo) -> [String] {
    return [
        "App: Nanogram iOS \(info.appVersion) (\(info.buildNumber)), \(info.bundleId)",
        "OS: \(info.osVersion)",
        "Device: \(info.deviceChip) (\(info.deviceModelIdentifier))"
    ]
}

func debugReportInfoText(_ info: DebugReportInfo) -> String {
    var lines = debugReportInfoLines(info)
    lines.append("Running as: \(info.isMainApp ? "main app" : "extension"), account signed in: \(info.hasAccount ? "yes" : "no")")
    lines.append("Log to File: \(info.logToFile ? "on" : "off"), Remove Sensitive Data: \(info.redactSensitiveData ? "on" : "off")")
    lines.append("Low Power Mode: \(info.lowPowerMode ? "on" : "off"), thermal state: \(info.thermalState)")
    lines.append("Locale: \(info.localeIdentifier)")
    lines.append("Store build: \(info.isStoreBuild ? "yes (Premium and Stars purchases hidden)" : "no")")
    lines.append("")
    lines.append(info.experimentsReport)
    lines.append("")
    return lines.joined(separator: "\n")
}

private func debugReportThermalName(_ state: ProcessInfo.ThermalState) -> String {
    switch state {
    case .nominal: return "nominal"
    case .fair: return "fair"
    case .serious: return "serious"
    case .critical: return "critical"
    @unknown default: return "unknown"
    }
}

private func debugReportCurrentInfo(sharedContext: SharedAccountContext, context: AccountContext?) -> DebugReportInfo {
    let info = Bundle.main.infoDictionary
    let identifier = debugDeviceModelIdentifier()
    return DebugReportInfo(
        appVersion: info?["CFBundleShortVersionString"] as? String ?? "?",
        buildNumber: info?[kCFBundleVersionKey as String] as? String ?? "?",
        bundleId: Bundle.main.bundleIdentifier ?? "?",
        osVersion: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
        deviceModelIdentifier: identifier,
        deviceChip: performanceExperimentsDeviceChip(identifier: identifier),
        isMainApp: sharedContext.applicationBindings.isMainApp,
        hasAccount: context != nil,
        logToFile: Logger.shared.logToFile,
        redactSensitiveData: Logger.shared.redactSensitiveData,
        lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
        thermalState: debugReportThermalName(ProcessInfo.processInfo.thermalState),
        localeIdentifier: Locale.current.identifier,
        experimentsReport: performanceExperimentsReport(modelIdentifier: identifier) + "\n\n" + MediaCapabilities.shared.reportLines().joined(separator: "\n")
    )
}

private func debugReportFileSources(section: DebugReportSection, files: [(String, String)], treatment: DebugReportTreatment, namePrefix: String = "", newest: Int? = nil) -> [DebugReportSource] {
    var result: [DebugReportSource] = []
    for (name, path) in files {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
            continue
        }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date) ?? Date.distantPast
        result.append(DebugReportSource(section: section, name: namePrefix + name, path: path, treatment: treatment, modified: modified, size: size))
    }
    if let newest {
        result = Array(result.sorted { $0.modified > $1.modified }.prefix(max(0, newest)))
    }
    return result
}

private func debugReportLogger(_ sharedContext: SharedAccountContext, _ type: String) -> Logger {
    let path = sharedContext.basePath + "/logs/\(type)"
    return Logger(rootPath: path, basePath: path)
}

/// The files the report can hold, read on the export's preparation queue. Nothing is read from a chat or the database.
private func debugReportLocalSources(sharedContext: SharedAccountContext, context: AccountContext?) -> [DebugReportSource] {
    var sources: [DebugReportSource] = []
    let now = Date()
    let info = debugReportCurrentInfo(sharedContext: sharedContext, context: context)
    sources.append(DebugReportSource(section: .info, name: "device-and-experiments.txt", text: debugReportInfoText(info), modified: now))
    sources.append(DebugReportSource(section: .energy, name: "energy.txt", text: DebugEnergy.monitor.report(context: DebugEnergy.currentContext()), modified: now))

    if let reports = try? CrashReportStore.shared.reports() {
        for report in reports {
            sources.append(DebugReportSource(section: .crashes, name: "crash-\(report.id.prefix(12)).txt", text: report.text, treatment: .plainText, modified: report.receivedAt))
        }
    }
    var metricFiles = MetricReportStore.shared.reports().map { ($0.name, $0.path) }
    if let reporter = DiskWriteAccountingReporting.current, let ledgerPath = DiskWriteAccountingReporting.ledgerPath {
        reporter.report(reason: "export")
        if FileManager.default.fileExists(atPath: ledgerPath) {
            metricFiles.append(("disk-writes.json", ledgerPath))
        }
    }
    sources.append(contentsOf: debugReportFileSources(section: .metricKit, files: metricFiles, treatment: .unchanged))
    if let context {
        let calls = debugCallLogFiles(in: callLogsPath(account: context.account), limit: 5).map { ($0.0, $0.1) }
        sources.append(contentsOf: debugReportFileSources(section: .callLogs, files: calls, treatment: .redactedText))
    }
    return sources
}

/// Everything the report holds, collected on the export preparation queue.
func debugReportSourcesSignal(sharedContext: SharedAccountContext, context: AccountContext?) -> Signal<[DebugReportSource], NoError> {
    let logTypes: [(DebugReportSection, String)] = [
        (.shareLogs, "share-logs"),
        (.notificationLogs, "notification-logs"),
        (.otherExtensionLogs, "broadcast-logs"),
        (.otherExtensionLogs, "siri-logs"),
        (.otherExtensionLogs, "widget-logs"),
        (.otherExtensionLogs, "notificationcontent-logs"),
        (.cpuProfiles, "profile-logs")
    ]
    var signals: [Signal<[DebugReportSource], NoError>] = []
    signals.append(Logger.shared.collectLogs()
    |> take(1)
    |> map { debugReportFileSources(section: .appLogs, files: $0, treatment: .redactedText) })
    signals.append(Logger.shared.collectShortLogFiles()
    |> take(1)
    |> map { debugReportFileSources(section: .criticalLogs, files: $0, treatment: .unchanged, namePrefix: "app-") })
    for (section, type) in logTypes {
        let logger = debugReportLogger(sharedContext, type)
        signals.append(logger.collectLogs()
        |> take(1)
        |> map { debugReportFileSources(section: section, files: $0, treatment: .redactedText, namePrefix: section == .otherExtensionLogs ? type + "-" : "") })
    }
    signals.append(debugReportLogger(sharedContext, "notification-logs").collectShortLogFiles()
    |> take(1)
    |> map { debugReportFileSources(section: .criticalLogs, files: $0, treatment: .unchanged, namePrefix: "nse-") })
    if let context {
        signals.append(Logger.shared.collectLogs(basePath: context.account.basePath + "/group-calls")
        |> take(1)
        |> map { debugReportFileSources(section: .groupCallLogs, files: $0, treatment: .redactedText, newest: 3) })
    }
    return combineLatest(signals)
    |> take(1)
    |> deliverOn(debugLogExportPreparationQueue())
    |> map { groups -> [DebugReportSource] in
        return debugReportLocalSources(sharedContext: sharedContext, context: context) + groups.flatMap { $0 }
    }
}

/// The paired watch's part: its files (or nothing) and the README line that says where they came from.
private func debugReportWatchSignal() -> Signal<(files: [WatchReportFile], created: Date?, line: String), NoError> {
    return Signal { subscriber in
        WatchReportClient.shared.fetch { result in
            subscriber.putNext((result.files, result.created, result.statusLine))
            subscriber.putCompletion()
        }
        return EmptyDisposable
    }
}

func debugReportWatchSources(files: [WatchReportFile], created: Date?) -> [DebugReportSource] {
    return files.map { DebugReportSource(section: .watch, name: $0.name, text: $0.text, modified: created ?? Date()) }
}

/// The prepare step of the "Send Report" export: one zip with a README.
func debugReportPrepare(sharedContext: SharedAccountContext, context: AccountContext?) -> (URL, DebugLogExportSpec) -> Signal<[DebugLogExportFile], NoError> {
    return { directory, spec in
        return combineLatest(debugReportSourcesSignal(sharedContext: sharedContext, context: context), debugReportWatchSignal())
        |> take(1)
        |> deliverOn(debugLogExportPreparationQueue())
        |> map { sources, watch -> [DebugLogExportFile] in
            let created = Date()
            let plan = debugReportPlan(sources: sources + debugReportWatchSources(files: watch.files, created: watch.created), now: created)
            let info = debugReportCurrentInfo(sharedContext: sharedContext, context: context)
            let manifest = debugReportManifest(infoLines: debugReportInfoLines(info), watchLine: watch.line, plan: plan, created: created)
            return debugReportArchive(plan: plan, manifest: manifest, baseName: spec.fileBaseName, in: directory).flatMap { [$0] } ?? []
        }
    }
}

/// Starts "Send Report" from a screen with an account: where to send it is asked next (a chat, an email or another app).
public func triggerDebugSendReportUI(context: AccountContext, pushController: @escaping (ViewController) -> Void) {
    let host = DebugLogExportHost(sharedContext: context.sharedContext, context: context, present: { [weak context] controller in
        context?.sharedContext.mainWindow?.present(controller, on: .root)
    }, push: pushController, rootViewController: { [weak context] in
        return context?.sharedContext.mainWindow?.hostView.containerView.window?.rootViewController
    })
    presentDebugLogExport(host: host, kind: .report, prepare: debugReportPrepare(sharedContext: context.sharedContext, context: context))
}
