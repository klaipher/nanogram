import Foundation
import UIKit
import MessageUI
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import PresentationDataUtils
import AccountContext
import ZipArchive

// Every way logs, reports and diagnostics leave the device from Debug Settings goes through
// `presentDebugLogExport`: the user picks where they go (a chat of their choice, an email, or another app),
// and nothing is sent to a fixed chat or bot. Each kind keeps its own file collection (`prepare`); only the
// destination step is shared.

/// Everything Debug Settings (and the chat "Send Logs" action) can export.
enum DebugLogExportKind: CaseIterable, Equatable {
    case logs
    case shareLogs
    case groupCallLogs
    case notificationLogs
    case criticalLogs
    case allLogs
    case storageStats
    case profileLogs
    case metricKitReports
    case crashReport
    case mediaDownloadLogs
}

/// Where an export can go. There is deliberately no case that carries a fixed peer or username.
enum DebugLogExportDestination: CaseIterable, Equatable {
    /// A chat the user picks in the peer selection controller.
    case nanogram
    /// Mail with the files attached; the share sheet when no Mail account is set up.
    case email
    /// The share sheet: Files, AirDrop, other apps.
    case otherApps

    var title: String {
        switch self {
        case .nanogram: return "Via Nanogram…"
        case .email: return "Via Email…"
        case .otherApps: return "Other Apps…"
        }
    }
}

/// The user-visible texts and file names of one export.
struct DebugLogExportSpec: Equatable {
    /// What is sent, title case: "Logs", "Crash Log".
    var what: String
    /// The action sheet title: "Send Logs".
    var sheetTitle: String
    /// An optional line under the title describing what the files contain.
    var note: String?
    /// The email subject: "Nanogram iOS logs (13.1.2 (202611031553))".
    var subject: String
    /// The base of every attachment / archive name: "nanogram-logs-full".
    var fileBaseName: String
}

func debugLogExportSpec(_ kind: DebugLogExportKind, appVersion: String, buildNumber: String) -> DebugLogExportSpec {
    let what: String
    let lowercased: String
    let base: String
    var note: String?
    switch kind {
    case .logs:
        what = "Logs"
        lowercased = "logs"
        base = "full"
    case .shareLogs:
        what = "Share Logs"
        lowercased = "share extension logs"
        base = "share"
    case .groupCallLogs:
        what = "Group Call Logs"
        lowercased = "group call logs"
        base = "group-calls"
    case .notificationLogs:
        what = "Notification Logs"
        lowercased = "notification logs"
        base = "notifications"
    case .criticalLogs:
        what = "Critical Logs"
        lowercased = "critical logs"
        base = "critical"
    case .allLogs:
        what = "All Logs"
        lowercased = "all logs"
        base = "all"
    case .storageStats:
        what = "Storage Stats"
        lowercased = "storage stats"
        base = "storage-stats"
    case .profileLogs:
        what = "Profile Logs"
        lowercased = "CPU profiles"
        base = "cpu-profiles"
    case .metricKitReports:
        what = "MetricKit Reports"
        lowercased = "MetricKit reports"
        base = "metrickit"
    case .crashReport:
        what = "Crash Log"
        lowercased = "crash log"
        base = "crash"
        note = "The archive includes the crash diagnostic, app and device details, and stack addresses. You can review these in View Log."
    case .mediaDownloadLogs:
        what = "Logs"
        lowercased = "media download logs"
        base = "media-download"
    }
    return DebugLogExportSpec(
        what: what,
        sheetTitle: "Send \(what)",
        note: note,
        subject: "Nanogram iOS \(lowercased) (\(appVersion) (\(buildNumber)))",
        fileBaseName: "nanogram-logs-\(base)"
    )
}

/// The destinations offered for an export. A chat can only be picked in the main app with an account.
func debugLogExportDestinations(canSendInApp: Bool) -> [DebugLogExportDestination] {
    return canSendInApp ? [.nanogram, .email, .otherApps] : [.email, .otherApps]
}

/// One prepared file of an export.
struct DebugLogExportFile: Equatable {
    var name: String
    var path: String
    var mimeType: String
}

/// What the export flow needs from the screen it starts on.
struct DebugLogExportHost {
    var sharedContext: SharedAccountContext
    var context: AccountContext?
    /// Presents a Display controller (the action sheet, alerts) over the screen.
    var present: (ViewController) -> Void
    /// Pushes the chat picker.
    var push: (ViewController) -> Void
    /// The UIKit root the Mail composer and the share sheet are presented from.
    var rootViewController: () -> UIViewController?

    var canSendInApp: Bool {
        return self.context != nil && self.sharedContext.applicationBindings.isMainApp
    }
}

private func debugAppVersion() -> (String, String) {
    let info = Bundle.main.infoDictionary
    let version = info?["CFBundleShortVersionString"] as? String ?? "?"
    let build = info?[kCFBundleVersionKey as String] as? String ?? "?"
    return (version, build)
}

/// A fresh directory for one export's files; removed when the export is delivered.
private func makeDebugLogExportDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("nanogram-log-export", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let _ = try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func removeDebugLogExportDirectory(_ directory: URL) {
    let _ = try? FileManager.default.removeItem(at: directory)
}

/// Log files joined into one text, each preceded by a "------ File: name ------" line.
func debugLogConcatenatedData(logs: [(String, String)], additionalInfo: String? = nil) -> Data {
    let lineFeed = Data("\n".utf8)
    var rawLogData = Data()
    for (name, path) in logs {
        if !rawLogData.isEmpty {
            rawLogData.append(lineFeed)
            rawLogData.append(lineFeed)
        }
        rawLogData.append(Data("------ File: \(name) ------\n".utf8))
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
            rawLogData.append(data)
        }
    }
    if let additionalInfo, !additionalInfo.isEmpty {
        rawLogData.append(Data("------ Additional Info ------\n".utf8))
        rawLogData.append(Data(additionalInfo.utf8))
    }
    return rawLogData
}

/// Joins log files into "<baseName>.txt" and zips it into "<baseName>.zip".
func debugLogConcatenatedArchive(logs: [(String, String)], additionalInfo: String? = nil, baseName: String, in directory: URL) -> DebugLogExportFile? {
    let source = directory.appendingPathComponent("\(baseName).txt")
    guard let _ = try? debugLogConcatenatedData(logs: logs, additionalInfo: additionalInfo).write(to: source) else {
        return nil
    }
    return debugLogZip(sources: [source], baseName: baseName, in: directory)
}

/// Zips files already in the export directory into "<baseName>.zip".
func debugLogZip(sources: [URL], baseName: String, in directory: URL) -> DebugLogExportFile? {
    let archive = directory.appendingPathComponent("\(baseName).zip")
    guard SSZipArchive.createZipFile(atPath: archive.path, withFilesAtPaths: sources.map(\.path)) else {
        return nil
    }
    for source in sources {
        let _ = try? FileManager.default.removeItem(at: source)
    }
    return DebugLogExportFile(name: archive.lastPathComponent, path: archive.path, mimeType: "application/zip")
}

/// Copies files into the export directory under "<baseName>-<original name>", one attachment each.
func debugLogCopiedFiles(logs: [(String, String)], baseName: String, mimeType: String, in directory: URL) -> [DebugLogExportFile] {
    var result: [DebugLogExportFile] = []
    for (name, path) in logs {
        let target = directory.appendingPathComponent("\(baseName)-\(name)")
        do {
            try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: target)
            result.append(DebugLogExportFile(name: target.lastPathComponent, path: target.path, mimeType: mimeType))
        } catch {
        }
    }
    return result
}

private final class DebugLogMailComposeDelegate: NSObject, MFMailComposeViewControllerDelegate {
    static let shared = DebugLogMailComposeDelegate()

    var directories: [ObjectIdentifier: URL] = [:]

    func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
        if let directory = self.directories.removeValue(forKey: ObjectIdentifier(controller)) {
            removeDebugLogExportDirectory(directory)
        }
        controller.dismiss(animated: true, completion: nil)
    }
}

private func topmostPresenter(_ host: DebugLogExportHost) -> UIViewController? {
    guard var presenter = host.rootViewController() else {
        return nil
    }
    while let presented = presenter.presentedViewController, !presented.isBeingDismissed {
        presenter = presented
    }
    return presenter
}

private func presentShareSheet(host: DebugLogExportHost, files: [DebugLogExportFile], directory: URL) {
    guard let presenter = topmostPresenter(host) else {
        removeDebugLogExportDirectory(directory)
        return
    }
    let activityController = UIActivityViewController(activityItems: files.map { URL(fileURLWithPath: $0.path) }, applicationActivities: nil)
    activityController.completionWithItemsHandler = { _, _, _, _ in
        removeDebugLogExportDirectory(directory)
    }
    if let popover = activityController.popoverPresentationController {
        popover.sourceView = presenter.view
        popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 0.0, height: 0.0)
        popover.permittedArrowDirections = []
    }
    presenter.present(activityController, animated: true, completion: nil)
}

/// Opens Mail with the files attached when a Mail account is set up, and the share sheet otherwise.
/// Presenting MFMailComposeViewController without a Mail account raises an exception (TestFlight crash
/// report: SIGABRT in -[UIViewController presentViewController:] from DebugLogAction.perform). It is
/// presented from the topmost controller, so a sheet still on screen cannot reject the presentation.
private func presentMailOrShareSheet(host: DebugLogExportHost, subject: String, files: [DebugLogExportFile], directory: URL) {
    guard MFMailComposeViewController.canSendMail() else {
        presentShareSheet(host: host, files: files, directory: directory)
        return
    }
    guard let presenter = topmostPresenter(host) else {
        removeDebugLogExportDirectory(directory)
        return
    }
    let composeController = MFMailComposeViewController()
    composeController.mailComposeDelegate = DebugLogMailComposeDelegate.shared
    DebugLogMailComposeDelegate.shared.directories[ObjectIdentifier(composeController)] = directory
    composeController.setSubject(subject)
    for file in files {
        if let data = try? Data(contentsOf: URL(fileURLWithPath: file.path), options: .mappedIfSafe) {
            composeController.addAttachmentData(data, mimeType: file.mimeType, fileName: file.name)
        }
    }
    presenter.present(composeController, animated: true, completion: nil)
}

private func sendToChat(context: AccountContext, peerId: EnginePeer.Id, files: [DebugLogExportFile], directory: URL) {
    var messages: [EnqueueMessage] = []
    for file in files {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: file.path)) else {
            continue
        }
        let id = Int64.random(in: Int64.min ... Int64.max)
        let resource = LocalFileMediaResource(fileId: id, size: Int64(data.count), isSecretRelated: false)
        context.engine.resources.storeResourceData(id: EngineMediaResource.Id(resource.id), data: data)
        let media = TelegramMediaFile(fileId: EngineMedia.Id(namespace: Namespaces.Media.LocalFile, id: id), partialReference: nil, resource: resource, previewRepresentations: [], videoThumbnails: [], immediateThumbnailData: nil, mimeType: file.mimeType, size: Int64(data.count), attributes: [.FileName(fileName: file.name)], alternativeRepresentations: [])
        messages.append(.message(text: "", attributes: [], inlineStickers: [:], mediaReference: .standalone(media: media), threadId: nil, replyToMessageId: nil, replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: []))
    }
    removeDebugLogExportDirectory(directory)
    if !messages.isEmpty {
        let _ = enqueueMessages(account: context.account, peerId: peerId, messages: messages).start()
    }
}

private func presentNothingToSend(host: DebugLogExportHost, spec: DebugLogExportSpec) {
    let presentationData = host.sharedContext.currentPresentationData.with { $0 }
    host.present(textAlertController(sharedContext: host.sharedContext, title: "Could Not Prepare \(spec.what)", text: "There was nothing to send, or the files could not be written. Please try again.", actions: [
        TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})
    ]))
}

/// Prepares the files off the main queue, then hands them to `deliver` on the main queue.
private func prepareDebugLogExport(host: DebugLogExportHost, spec: DebugLogExportSpec, prepare: @escaping (URL, DebugLogExportSpec) -> Signal<[DebugLogExportFile], NoError>, deliver: @escaping ([DebugLogExportFile], URL) -> Void) {
    let directory = makeDebugLogExportDirectory()
    let _ = (prepare(directory, spec)
    |> take(1)
    |> deliverOnMainQueue).start(next: { files in
        if files.isEmpty {
            removeDebugLogExportDirectory(directory)
            presentNothingToSend(host: host, spec: spec)
        } else {
            deliver(files, directory)
        }
    })
}

/// Runs one export to the destination the user picked.
func performDebugLogExport(host: DebugLogExportHost, kind: DebugLogExportKind, destination: DebugLogExportDestination, prepare: @escaping (URL, DebugLogExportSpec) -> Signal<[DebugLogExportFile], NoError>) {
    let (version, build) = debugAppVersion()
    let spec = debugLogExportSpec(kind, appVersion: version, buildNumber: build)
    switch destination {
    case .nanogram:
        guard let context = host.context, host.canSendInApp else {
            return
        }
        let controller = context.sharedContext.makePeerSelectionController(PeerSelectionControllerParams(context: context, filter: [.onlyWriteable, .excludeDisabled]))
        controller.peerSelected = { [weak controller] peer, _ in
            controller?.dismiss()
            let peerId = peer.id
            prepareDebugLogExport(host: host, spec: spec, prepare: prepare, deliver: { files, directory in
                sendToChat(context: context, peerId: peerId, files: files, directory: directory)
            })
        }
        host.push(controller)
    case .email:
        prepareDebugLogExport(host: host, spec: spec, prepare: prepare, deliver: { files, directory in
            presentMailOrShareSheet(host: host, subject: spec.subject, files: files, directory: directory)
        })
    case .otherApps:
        prepareDebugLogExport(host: host, spec: spec, prepare: prepare, deliver: { files, directory in
            presentShareSheet(host: host, files: files, directory: directory)
        })
    }
}

/// Asks where to send an export ("Via Nanogram…", "Via Email…", "Other Apps…") and sends it there.
/// `prepare` writes the export's files into the directory it is given; it runs only after a destination
/// (and, for a chat, the chat) has been picked.
func presentDebugLogExport(host: DebugLogExportHost, kind: DebugLogExportKind, prepare: @escaping (URL, DebugLogExportSpec) -> Signal<[DebugLogExportFile], NoError>) {
    let (version, build) = debugAppVersion()
    let spec = debugLogExportSpec(kind, appVersion: version, buildNumber: build)
    let presentationData = host.sharedContext.currentPresentationData.with { $0 }
    let actionSheet = ActionSheetController(presentationData: presentationData)

    var items: [ActionSheetItem] = []
    var title = spec.sheetTitle
    if let note = spec.note {
        title += "\n\n" + note
    }
    items.append(ActionSheetTextItem(title: title, parseMarkdown: false))
    for destination in debugLogExportDestinations(canSendInApp: host.canSendInApp) {
        items.append(ActionSheetButtonItem(title: destination.title, color: .accent, action: { [weak actionSheet] in
            actionSheet?.dismissAnimated()
            performDebugLogExport(host: host, kind: kind, destination: destination, prepare: prepare)
        }))
    }
    actionSheet.setItemGroups([
        ActionSheetItemGroup(items: items),
        ActionSheetItemGroup(items: [
            ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
            })
        ])
    ])
    host.present(actionSheet)
}

/// Collected log files as one zipped text file: the shape most kinds use.
func debugLogConcatenatedArchiveSignal(_ logs: Signal<[(String, String)], NoError>, additionalInfo: String? = nil) -> (URL, DebugLogExportSpec) -> Signal<[DebugLogExportFile], NoError> {
    return { directory, spec in
        return logs
        |> take(1)
        |> deliverOn(Queue.concurrentDefaultQueue())
        |> map { logs -> [DebugLogExportFile] in
            return debugLogConcatenatedArchive(logs: logs, additionalInfo: additionalInfo, baseName: spec.fileBaseName, in: directory).flatMap { [$0] } ?? []
        }
    }
}
