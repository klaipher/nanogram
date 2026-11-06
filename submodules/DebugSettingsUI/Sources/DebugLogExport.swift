import Foundation
import UIKit
import MessageUI
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import PresentationDataUtils
import AccountContext
import OverlayStatusController
import UndoUI
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
    case callLogs
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
    /// Sending to a chat asks first, naming the chat and the account it is sent from.
    var confirmsChatSend: Bool = false
    /// A line added to the alert shown when the files could not be prepared or sent.
    var failureNote: String?
}

func debugLogExportSpec(_ kind: DebugLogExportKind, appVersion: String, buildNumber: String) -> DebugLogExportSpec {
    let what: String
    let lowercased: String
    let base: String
    var note: String?
    var confirmsChatSend = false
    var failureNote: String?
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
    case .callLogs:
        what = "Call Logs"
        lowercased = "call logs"
        base = "calls"
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
        confirmsChatSend = true
        failureNote = "The log remains saved on this device."
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
        fileBaseName: "nanogram-logs-\(base)",
        confirmsChatSend: confirmsChatSend,
        failureNote: failureNote
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

/// Lets one export run at a time, from the moment its files start being prepared until they are handed to their
/// destination (Mail or the share sheet presented, the chat messages queued). Main queue only.
final class DebugLogExportGate {
    static let shared = DebugLogExportGate()

    private var current: Int?
    private var nextToken = 0

    var isRunning: Bool {
        return self.current != nil
    }

    /// A token for `end`, or nil while another export runs.
    func begin() -> Int? {
        if self.current != nil {
            return nil
        }
        self.nextToken += 1
        self.current = self.nextToken
        return self.nextToken
    }

    /// Ends the run `token` began; a stale token does nothing.
    func end(_ token: Int) {
        if self.current == token {
            self.current = nil
        }
    }
}

/// Prepares an export's files under `gate` and returns false, doing nothing, while another export runs.
/// `showProgress` is called when preparation starts and returns what hides it again. On the main queue, `deliver`
/// gets the files, their directory and `finish`, which it calls once the files are handed over (it ends the run).
/// Without files the directory is removed, the run ends and `nothingToSend` is called.
@discardableResult
func runDebugLogExport(gate: DebugLogExportGate, spec: DebugLogExportSpec, prepare: @escaping (URL, DebugLogExportSpec) -> Signal<[DebugLogExportFile], NoError>, showProgress: () -> (() -> Void), nothingToSend: @escaping () -> Void, deliver: @escaping ([DebugLogExportFile], URL, @escaping () -> Void) -> Void) -> Bool {
    guard let token = gate.begin() else {
        return false
    }
    let directory = makeDebugLogExportDirectory()
    let hideProgress = showProgress()
    var handled = false
    let handle: ([DebugLogExportFile]) -> Void = { files in
        if handled {
            return
        }
        handled = true
        hideProgress()
        if files.isEmpty {
            removeDebugLogExportDirectory(directory)
            gate.end(token)
            nothingToSend()
        } else {
            deliver(files, directory, {
                gate.end(token)
            })
        }
    }
    let _ = (prepare(directory, spec)
    |> take(1)
    |> deliverOnMainQueue).start(next: { files in
        handle(files)
    }, completed: {
        handle([])
    })
    return true
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

/// Zips files unchanged, under their own names, into "<baseName>.zip" in the export directory.
func debugLogFilesArchive(logs: [(String, String)], baseName: String, in directory: URL) -> DebugLogExportFile? {
    let staging = directory.appendingPathComponent(baseName, isDirectory: true)
    guard let _ = try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true) else {
        return nil
    }
    defer {
        let _ = try? FileManager.default.removeItem(at: staging)
    }
    var sources: [URL] = []
    for (name, path) in logs {
        let target = staging.appendingPathComponent((name as NSString).lastPathComponent)
        if let _ = try? FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: target) {
            sources.append(target)
        }
    }
    if sources.isEmpty {
        return nil
    }
    return debugLogZip(sources: sources, baseName: baseName, in: directory)
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

/// The share sheet reports a share extension cancelled inside it (`completed == false` with its activity type) while it
/// stays open, and the files are still offered; they go once an activity completes or the sheet is dismissed
/// (`activityType == nil`).
func debugLogShareSheetRemovesExport(completed: Bool, activityType: UIActivity.ActivityType?) -> Bool {
    return completed || activityType == nil
}

private func presentShareSheet(host: DebugLogExportHost, files: [DebugLogExportFile], directory: URL) {
    guard let presenter = topmostPresenter(host) else {
        removeDebugLogExportDirectory(directory)
        return
    }
    let activityController = UIActivityViewController(activityItems: files.map { URL(fileURLWithPath: $0.path) }, applicationActivities: nil)
    activityController.completionWithItemsHandler = { activityType, completed, _, _ in
        if debugLogShareSheetRemovesExport(completed: completed, activityType: activityType) {
            removeDebugLogExportDirectory(directory)
        }
    }
    if let popover = activityController.popoverPresentationController {
        popover.sourceView = presenter.view
        popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 0.0, height: 0.0)
        popover.permittedArrowDirections = []
    }
    presenter.present(activityController, animated: true, completion: nil)
}

struct DebugLogMailAttachment {
    let data: Data
    let mimeType: String
    let fileName: String
}

/// Reads the files for a Mail composer off the main queue (a full export can be tens of MB) and hands them back on the
/// main queue, in order; a file that cannot be read is left out.
func loadDebugLogMailAttachments(files: [DebugLogExportFile], read: @escaping (String) -> Data? = { path in
    return try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
}, completion: @escaping ([DebugLogMailAttachment]) -> Void) {
    Queue.concurrentDefaultQueue().async {
        let attachments = files.compactMap { file -> DebugLogMailAttachment? in
            guard let data = read(file.path) else {
                return nil
            }
            return DebugLogMailAttachment(data: data, mimeType: file.mimeType, fileName: file.name)
        }
        Queue.mainQueue().async {
            completion(attachments)
        }
    }
}

/// Opens Mail with the files attached when a Mail account is set up, and the share sheet otherwise.
/// Presenting MFMailComposeViewController without a Mail account raises an exception (TestFlight crash
/// report: SIGABRT in -[UIViewController presentViewController:] from DebugLogAction.perform). It is
/// presented from the topmost controller, so a sheet still on screen cannot reject the presentation.
private func presentMailOrShareSheet(host: DebugLogExportHost, subject: String, files: [DebugLogExportFile], directory: URL, finish: @escaping () -> Void) {
    guard MFMailComposeViewController.canSendMail() else {
        presentShareSheet(host: host, files: files, directory: directory)
        finish()
        return
    }
    loadDebugLogMailAttachments(files: files, completion: { attachments in
        defer {
            finish()
        }
        guard let presenter = topmostPresenter(host) else {
            removeDebugLogExportDirectory(directory)
            return
        }
        let composeController = MFMailComposeViewController()
        composeController.mailComposeDelegate = DebugLogMailComposeDelegate.shared
        DebugLogMailComposeDelegate.shared.directories[ObjectIdentifier(composeController)] = directory
        composeController.setSubject(subject)
        for attachment in attachments {
            composeController.addAttachmentData(attachment.data, mimeType: attachment.mimeType, fileName: attachment.fileName)
        }
        presenter.present(composeController, animated: true, completion: nil)
    })
}

enum DebugLogChatUploadState: Equatable {
    /// Sent (stored again under its server id, so the local id reads nil) or deleted.
    case gone
    case sent
    case sending
    /// Failed; the chat's Retry reads the file again while it is still there.
    case failed(fileExists: Bool)
}

/// Whether a chat export's directory can go: every message has left, or failed after its upload took the file.
func debugLogChatUploadsSettled(_ states: [DebugLogChatUploadState]) -> Bool {
    return states.allSatisfy { state in
        switch state {
        case .gone, .sent:
            return true
        case .sending:
            return false
        case let .failed(fileExists):
            return !fileExists
        }
    }
}

/// Keeps a chat export's directory until its messages have left: they reference the files by path until the media box
/// takes them over when the upload starts, and a failed message keeps its file for Retry until it is sent or deleted.
/// Main queue only.
private final class DebugLogChatUploads {
    static let shared = DebugLogChatUploads()

    private var disposables: [URL: MetaDisposable] = [:]

    func keep(_ directory: URL, until messages: [(id: EngineMessage.Id, path: String)], context: AccountContext) {
        let disposable = MetaDisposable()
        self.disposables[directory] = disposable
        let paths = messages.map(\.path)
        disposable.set((context.engine.data.subscribe(EngineDataList(messages.map { TelegramEngine.EngineData.Item.Messages.Message(id: $0.id) }))
        |> filter { messages -> Bool in
            let states = zip(messages, paths).map { message, path -> DebugLogChatUploadState in
                guard let message else {
                    return .gone
                }
                if message.flags.contains(.Failed) {
                    return .failed(fileExists: FileManager.default.fileExists(atPath: path))
                }
                return message.flags.contains(.Unsent) ? .sending : .sent
            }
            return debugLogChatUploadsSettled(states)
        }
        |> take(1)
        |> deliverOnMainQueue).start(next: { [weak self] _ in
            removeDebugLogExportDirectory(directory)
            self?.disposables.removeValue(forKey: directory)?.dispose()
        }))
    }
}

private func debugLogFileSize(_ path: String) -> Int64? {
    return ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value
}

/// Sends the files as documents. They are read from disk by the upload (as Critical Logs always did), never on the
/// main queue, and the directory stays until the messages have left.
private func sendToChat(host: DebugLogExportHost, context: AccountContext, peer: EnginePeer, spec: DebugLogExportSpec, files: [DebugLogExportFile], directory: URL, finish: @escaping () -> Void) {
    let messages: [EnqueueMessage] = files.map { file in
        let id = Int64.random(in: Int64.min ... Int64.max)
        let size = debugLogFileSize(file.path)
        let resource = LocalFileReferenceMediaResource(localFilePath: file.path, randomId: id, isUniquelyReferencedTemporaryFile: true, size: size)
        let media = TelegramMediaFile(fileId: EngineMedia.Id(namespace: Namespaces.Media.LocalFile, id: id), partialReference: nil, resource: resource, previewRepresentations: [], videoThumbnails: [], immediateThumbnailData: nil, mimeType: file.mimeType, size: size, attributes: [.FileName(fileName: file.name)], alternativeRepresentations: [])
        return .message(text: "", attributes: [], inlineStickers: [:], mediaReference: .standalone(media: media), threadId: nil, replyToMessageId: nil, replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: [])
    }
    let _ = (enqueueMessages(account: context.account, peerId: peer.id, messages: messages)
    |> deliverOnMainQueue).start(next: { ids in
        finish()
        let presentationData = host.sharedContext.currentPresentationData.with { $0 }
        let queued = zip(ids, files).compactMap { id, file -> (id: EngineMessage.Id, path: String)? in
            return id.flatMap { (id: $0, path: file.path) }
        }
        if queued.isEmpty {
            removeDebugLogExportDirectory(directory)
            presentDebugLogExportFailure(host: host, title: "Could Not Send \(spec.what)", text: "Please try again.", spec: spec)
            return
        }
        DebugLogChatUploads.shared.keep(directory, until: queued, context: context)
        let savedMessages = peer.id == context.account.peerId
        let text = savedMessages ? "Sent to **Saved Messages**." : "Sent to **\(peer.debugDisplayTitle.replacingOccurrences(of: "*", with: ""))**."
        host.present(UndoOverlayController(presentationData: presentationData, content: .forward(savedMessages: savedMessages, text: text), elevatedLayout: false, animateInAsReplacement: false, action: { _ in
            return false
        }))
    })
}

private func presentDebugLogExportFailure(host: DebugLogExportHost, title: String, text: String, spec: DebugLogExportSpec) {
    let presentationData = host.sharedContext.currentPresentationData.with { $0 }
    var text = text
    if let failureNote = spec.failureNote {
        text += " " + failureNote
    }
    host.present(textAlertController(sharedContext: host.sharedContext, title: title, text: text, actions: [
        TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})
    ]))
}

private func presentNothingToSend(host: DebugLogExportHost, spec: DebugLogExportSpec) {
    presentDebugLogExportFailure(host: host, title: "Could Not Prepare \(spec.what)", text: "There was nothing to send, or the files could not be written. Please try again.", spec: spec)
}

/// The standard loading overlay, shown only if preparing takes longer than a moment.
private func showDebugLogExportProgress(host: DebugLogExportHost) -> () -> Void {
    var hidden = false
    var controller: ViewController?
    Queue.mainQueue().after(0.15, {
        if hidden {
            return
        }
        let presentationData = host.sharedContext.currentPresentationData.with { $0 }
        let progress = OverlayStatusController(theme: presentationData.theme, type: .loading(cancelled: nil))
        controller = progress
        host.present(progress)
    })
    return {
        hidden = true
        controller?.dismiss()
        controller = nil
    }
}

/// Prepares the files off the main queue under the loading overlay, then hands them to `deliver` on the main queue.
/// Does nothing while another export is being prepared or delivered.
private func prepareDebugLogExport(host: DebugLogExportHost, spec: DebugLogExportSpec, prepare: @escaping (URL, DebugLogExportSpec) -> Signal<[DebugLogExportFile], NoError>, deliver: @escaping ([DebugLogExportFile], URL, @escaping () -> Void) -> Void) {
    runDebugLogExport(gate: DebugLogExportGate.shared, spec: spec, prepare: prepare, showProgress: {
        return showDebugLogExportProgress(host: host)
    }, nothingToSend: {
        presentNothingToSend(host: host, spec: spec)
    }, deliver: deliver)
}

/// For kinds that ask first: names the chat and the account the files are sent from.
private func confirmChatSend(host: DebugLogExportHost, context: AccountContext, peer: EnginePeer, spec: DebugLogExportSpec, send: @escaping () -> Void) {
    let _ = (context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: context.account.peerId))
    |> deliverOnMainQueue).start(next: { account in
        let presentationData = host.sharedContext.currentPresentationData.with { $0 }
        var lines: [String] = []
        if peer.id == context.account.peerId {
            lines.append("To: Saved Messages")
        } else {
            lines.append("To: \(peer.debugDisplayTitle)")
        }
        if let account {
            var sender = account.debugDisplayTitle
            if let username = account.addressName, !username.isEmpty {
                sender += " (@\(username))"
            }
            lines.append("From: \(sender)")
        }
        var text = lines.joined(separator: "\n")
        if let note = spec.note {
            text += "\n\n" + note
        }
        host.present(textAlertController(sharedContext: host.sharedContext, title: "\(spec.sheetTitle)?", text: text, actions: [
            TextAlertAction(type: .genericAction, title: presentationData.strings.Common_Cancel, action: {}),
            TextAlertAction(type: .defaultAction, title: "Send", action: send)
        ]))
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
            let send = {
                prepareDebugLogExport(host: host, spec: spec, prepare: prepare, deliver: { files, directory, finish in
                    sendToChat(host: host, context: context, peer: peer, spec: spec, files: files, directory: directory, finish: finish)
                })
            }
            if spec.confirmsChatSend {
                confirmChatSend(host: host, context: context, peer: peer, spec: spec, send: send)
            } else {
                send()
            }
        }
        host.push(controller)
    case .email:
        prepareDebugLogExport(host: host, spec: spec, prepare: prepare, deliver: { files, directory, finish in
            presentMailOrShareSheet(host: host, subject: spec.subject, files: files, directory: directory, finish: finish)
        })
    case .otherApps:
        prepareDebugLogExport(host: host, spec: spec, prepare: prepare, deliver: { files, directory, finish in
            presentShareSheet(host: host, files: files, directory: directory)
            finish()
        })
    }
}

/// Asks where to send an export ("Via Nanogram…", "Via Email…", "Other Apps…") and sends it there.
/// `prepare` writes the export's files into the directory it is given; it runs only after a destination
/// (and, for a chat, the chat) has been picked. Ignored while another export is being prepared or delivered.
func presentDebugLogExport(host: DebugLogExportHost, kind: DebugLogExportKind, prepare: @escaping (URL, DebugLogExportSpec) -> Signal<[DebugLogExportFile], NoError>) {
    if DebugLogExportGate.shared.isRunning {
        return
    }
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

/// The queue an export prepares its files on. It is serial: on a concurrent queue the completion that follows the
/// prepared files could overtake them, and the export reported "nothing to send" while the files were still being
/// zipped (MetricKit reports, 2026-11-03..06).
func debugLogExportPreparationQueue() -> Queue {
    return Queue(name: "org.telegram.debug-log-export", qos: .utility)
}

/// Collected log files as one zipped text file: the shape most kinds use.
func debugLogConcatenatedArchiveSignal(_ logs: Signal<[(String, String)], NoError>, additionalInfo: String? = nil) -> (URL, DebugLogExportSpec) -> Signal<[DebugLogExportFile], NoError> {
    return { directory, spec in
        return logs
        |> take(1)
        |> deliverOn(debugLogExportPreparationQueue())
        |> map { logs -> [DebugLogExportFile] in
            return debugLogConcatenatedArchive(logs: logs, additionalInfo: additionalInfo, baseName: spec.fileBaseName, in: directory).flatMap { [$0] } ?? []
        }
    }
}

/// The logs of the newest 1:1 calls in `path`, newest call first: each call's "<id>_<time>.log" followed by its
/// rotated older half ".log.1" when there is one. The ".log.json" stats files and anything else are left out.
func debugCallLogFiles(in path: String, limit: Int) -> [(String, String)] {
    guard let urls = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else {
        return []
    }
    var calls: [String: (date: Date, log: URL?, rotated: URL?)] = [:]
    for url in urls {
        let name = url.lastPathComponent
        let stem: String
        let isRotated: Bool
        if name.hasSuffix(".log.1") {
            stem = String(name.dropLast(".log.1".count))
            isRotated = true
        } else if name.hasSuffix(".log") {
            stem = String(name.dropLast(".log".count))
            isRotated = false
        } else {
            continue
        }
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
        var entry = calls[stem] ?? (date: date, log: nil, rotated: nil)
        entry.date = max(entry.date, date)
        if isRotated {
            entry.rotated = url
        } else {
            entry.log = url
        }
        calls[stem] = entry
    }
    let newest = calls.sorted { lhs, rhs in
        if lhs.value.date != rhs.value.date {
            return lhs.value.date > rhs.value.date
        }
        return lhs.key > rhs.key
    }.prefix(max(0, limit))
    var result: [(String, String)] = []
    for (_, entry) in newest {
        for url in [entry.log, entry.rotated].compactMap({ $0 }) {
            result.append((url.lastPathComponent, url.path))
        }
    }
    return result
}

/// Files zipped unchanged under their own names (MetricKit's JSON reports, so each still opens as JSON).
func debugLogFilesArchiveSignal(_ logs: Signal<[(String, String)], NoError>) -> (URL, DebugLogExportSpec) -> Signal<[DebugLogExportFile], NoError> {
    return { directory, spec in
        return logs
        |> take(1)
        |> deliverOn(debugLogExportPreparationQueue())
        |> map { logs -> [DebugLogExportFile] in
            return debugLogFilesArchive(logs: logs, baseName: spec.fileBaseName, in: directory).flatMap { [$0] } ?? []
        }
    }
}
