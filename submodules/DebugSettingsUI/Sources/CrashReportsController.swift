import Foundation
import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences
import ItemListUI
import PresentationDataUtils
import AccountContext
import CrashReporting
import ZipArchive
import OverlayStatusController
import UndoUI
import ContextUI
import BuildConfig
#if DEBUG
import AppBundle
#endif

private let crashReportWorkQueue = DispatchQueue(label: "org.telegram.crash-report-ui", qos: .utility)

private struct CrashReportItemTag: ItemListItemTag {
    let id: String

    func isEqual(to other: ItemListItemTag) -> Bool {
        return (other as? CrashReportItemTag)?.id == self.id
    }
}

private final class CrashReportContextReferenceContentSource: ContextReferenceContentSource {
    private let sourceView: UIView

    init(sourceView: UIView) {
        self.sourceView = sourceView
    }

    func transitionInfo() -> ContextControllerReferenceViewInfo? {
        return ContextControllerReferenceViewInfo(referenceView: self.sourceView, contentAreaInScreenSpace: mainWindowScreenBounds, insets: UIEdgeInsets(top: -4.0, left: 0.0, bottom: -4.0, right: 0.0))
    }
}

private func crashReportsSignal() -> Signal<Result<[CrashReport], Error>, NoError> {
    return Signal { subscriber in
        let reload: () -> Void = {
            crashReportWorkQueue.async {
                subscriber.putNext(Result { try CrashReportStore.shared.reports() })
            }
        }
        let observer = NotificationCenter.default.addObserver(forName: CrashReportStore.didChange, object: nil, queue: nil) { _ in
            reload()
        }
        reload()
        return ActionDisposable {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

private func crashReportArchive(_ report: CrashReport) throws -> Data {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let json = directory.appendingPathComponent("crash.json")
    let metadata = directory.appendingPathComponent("metadata.json")
    let text = directory.appendingPathComponent("report.txt")
    try report.diagnosticJSON.write(to: json)
    try report.exportMetadata().write(to: metadata)
    try Data(report.text.utf8).write(to: text)
    let archive = directory.appendingPathComponent("report.zip")
    guard SSZipArchive.createZipFile(atPath: archive.path, withFilesAtPaths: [json.path, metadata.path, text.path]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    return try Data(contentsOf: archive)
}

private final class CrashReportActions {
    let sharedContext: SharedAccountContext
    let context: AccountContext?
    var present: (ViewController) -> Void = { _ in }
    var push: (ViewController) -> Void = { _ in }
    var presentMenu: (ViewController) -> Void = { _ in }
    var rootViewController: () -> UIViewController? = { nil }
    var reportNode: (String) -> ItemListDisclosureItemNode? = { _ in nil }
    private weak var presentedController: ViewController?
    var canPresent = true {
        didSet {
            if !self.canPresent {
                self.presentedController?.dismiss()
            }
        }
    }

    func show(_ controller: ViewController) {
        guard self.canPresent else { return }
        self.presentedController = controller
        self.present(controller)
    }

    init(sharedContext: SharedAccountContext, context: AccountContext?) {
        self.sharedContext = sharedContext
        self.context = context
    }

    func alert(_ title: String, _ text: String) {
        self.show(textAlertController(sharedContext: self.sharedContext, title: title, text: text, actions: [
            TextAlertAction(type: .defaultAction, title: self.sharedContext.currentPresentationData.with { $0 }.strings.Common_OK, action: {})
        ]))
    }

    #if DEBUG
    func testCrash() {
        let bundle = getAppBundle()
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unknown"
        #endif
        #if targetEnvironment(simulator)
        let deviceType = (ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? UIDevice.current.model) + " (Simulator)"
        #else
        let deviceType = UIDevice.current.model
        #endif
        let metadata = CrashReportMetadata(
            applicationVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown",
            buildVersion: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            deviceType: deviceType,
            architecture: architecture
        )
        do {
            try CrashReportStore.shared.simulateCrash(metadata: metadata, crash: {
                abort()
            })
        } catch {
            self.alert("Could Not Save Test Log", "The app was not crashed because the test log could not be saved.\n\n\(error.localizedDescription)")
        }
    }
    #endif

    func open(_ report: CrashReport) {
        guard self.canPresent, let sourceNode = self.reportNode(report.id) else { return }
        let data = self.sharedContext.currentPresentationData.with { $0 }
        let items: [ContextMenuItem] = [
            .action(ContextMenuActionItem(text: "View Log", icon: { theme in
                return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/File"), color: theme.contextMenu.primaryColor)
            }, action: { controller, _ in
                controller?.dismiss(completion: {
                    self.view(report)
                })
            })),
            .action(ContextMenuActionItem(text: "Send Crash Log…", icon: { theme in
                return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Forward"), color: theme.contextMenu.primaryColor)
            }, action: { controller, _ in
                controller?.dismiss(completion: {
                    self.send(report)
                })
            })),
            .action(ContextMenuActionItem(text: "Delete Log", textColor: .destructive, icon: { theme in
                return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Delete"), color: theme.contextMenu.destructiveColor)
            }, action: { controller, _ in
                controller?.dismiss(completion: {
                    self.show(textAlertController(sharedContext: self.sharedContext, title: "Delete Crash Log?", text: "This removes the saved log from this device.", actions: [
                        TextAlertAction(type: .genericAction, title: data.strings.Common_Cancel, action: {}),
                        TextAlertAction(type: .destructiveAction, title: "Delete", action: {
                            crashReportWorkQueue.async {
                                do {
                                    try CrashReportStore.shared.remove(id: report.id)
                                } catch {
                                    DispatchQueue.main.async { self.alert("Could Not Delete Log", "Please try again.") }
                                }
                            }
                        })
                    ]))
                })
            }))
        ]
        let controller = makeContextController(
            presentationData: data,
            source: .reference(CrashReportContextReferenceContentSource(sourceView: sourceNode.view)),
            items: .single(ContextController.Items(content: .list(items))),
            gesture: nil
        )
        sourceNode.updateHasContextMenu(hasContextMenu: true)
        controller.dismissed = { [weak sourceNode] in
            sourceNode?.updateHasContextMenu(hasContextMenu: false)
        }
        self.presentedController = controller
        self.presentMenu(controller)
    }

    private func view(_ report: CrashReport) {
        crashReportWorkQueue.async {
            let text = report.text
            DispatchQueue.main.async {
                self.push(CrashReportTextController(presentationData: self.sharedContext.currentPresentationData.with { $0 }, text: text))
            }
        }
    }

    /// Asks where to send the crash log (a chat the user picks, an email, another app) and sends its archive there.
    func send(_ report: CrashReport) {
        guard self.canPresent else { return }
        let host = DebugLogExportHost(sharedContext: self.sharedContext, context: self.context, present: { [weak self] controller in
            self?.show(controller)
        }, push: { [weak self] controller in
            self?.push(controller)
        }, rootViewController: { [weak self] in
            return self?.rootViewController()
        })
        presentDebugLogExport(host: host, kind: .crashReport, prepare: { directory, spec in
            return Signal { subscriber in
                crashReportWorkQueue.async {
                    do {
                        let data = try crashReportArchive(report)
                        let target = directory.appendingPathComponent("\(spec.fileBaseName)-\(report.id.prefix(12)).zip")
                        try data.write(to: target)
                        subscriber.putNext([DebugLogExportFile(name: target.lastPathComponent, path: target.path, mimeType: "application/zip")])
                    } catch {
                        subscriber.putNext([])
                    }
                    subscriber.putCompletion()
                }
                return EmptyDisposable
            }
        })
    }
}

private enum CrashReportEntry: ItemListNodeEntry {
    case showAlerts(PresentationTheme, Bool)
    case alertsInfo(PresentationTheme)
    case reportsHeader(PresentationTheme)
    case report(Int, PresentationTheme, CrashReport)
    case information(PresentationTheme, String)

    var section: ItemListSectionId {
        switch self {
        case .showAlerts, .alertsInfo: return 0
        case .reportsHeader, .report, .information: return 1
        }
    }
    var stableId: String {
        switch self {
        case .showAlerts: return "showAlerts"
        case .alertsInfo: return "alertsInfo"
        case .reportsHeader: return "reportsHeader"
        case let .report(_, _, report): return report.id
        case .information: return "information"
        }
    }
    private var index: Int {
        switch self {
        case .showAlerts: return -3
        case .alertsInfo: return -2
        case .reportsHeader: return -1
        case let .report(index, _, _): return index
        case .information: return Int.max
        }
    }
    static func < (lhs: CrashReportEntry, rhs: CrashReportEntry) -> Bool { return lhs.index < rhs.index }
    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        switch self {
        case let .showAlerts(_, value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Ask to Send Crash Logs", value: value, sectionId: self.section, style: .blocks, updated: { value in
                guard let actions = arguments as? CrashReportActions else { return }
                let _ = updateExperimentalUISettingsInteractively(accountManager: actions.sharedContext.accountManager, { settings in
                    var settings = settings
                    settings.showCrashReportAlerts = value
                    return settings
                }).start()
            })
        case .alertsInfo:
            return ItemListTextItem(presentationData: presentationData, text: .plain("After Nanogram crashes, offer to send the crash log to someone who can look at it."), sectionId: self.section)
        case .reportsHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "RECENT CRASHES", sectionId: self.section)
        case let .report(_, _, report):
            let date = DateFormatter.localizedString(from: report.receivedAt, dateStyle: .short, timeStyle: .short)
            let version = "\(report.metadata.applicationVersion) (\(report.metadata.buildVersion))"
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: date, label: version, sectionId: self.section, style: .blocks, action: {
                (arguments as? CrashReportActions)?.open(report)
            }, tag: CrashReportItemTag(id: report.id))
        case let .information(_, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}

public func crashReportsController(sharedContext: SharedAccountContext, context: AccountContext?) -> ViewController {
    let actions = CrashReportActions(sharedContext: sharedContext, context: context)
    let isInternalBuild = BuildConfig(baseAppBundleId: sharedContext.applicationBindings.appBundleId).isInternalBuild
    let signal = combineLatest(sharedContext.presentationData, crashReportsSignal(), sharedContext.accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.experimentalUISettings]))
    |> map { presentationData, result, sharedData -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let settings = sharedData.entries[ApplicationSpecificSharedDataKeys.experimentalUISettings]?.get(ExperimentalUISettings.self) ?? .defaultSettings
        var entries: [CrashReportEntry] = [
            .showAlerts(presentationData.theme, crashReportAlertsEnabled(override: settings.showCrashReportAlerts, isInternalBuild: isInternalBuild)),
            .alertsInfo(presentationData.theme)
        ]
        switch result {
        case let .success(reports):
            if !reports.isEmpty {
                entries.append(.reportsHeader(presentationData.theme))
            }
            entries.append(contentsOf: reports.enumerated().map { .report($0.offset, presentationData.theme, $0.element) })
            entries.append(.information(presentationData.theme, reports.isEmpty ? "No recent crash logs yet." : "The 10 most recent crash logs are displayed here."))
        case .failure:
            entries.append(.information(presentationData.theme, "Unknown Error Occured."))
        }
        let rightNavigationButton: ItemListNavigationButton?
        #if DEBUG
        rightNavigationButton = ItemListNavigationButton(content: .text("Test"), style: .regular, enabled: true, action: {
            actions.testCrash()
        })
        #else
        rightNavigationButton = nil
        #endif
        let state = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text("Crash Logs"), leftNavigationButton: nil, rightNavigationButton: rightNavigationButton, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        return (state, (ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks), actions))
    }
    let controller = ItemListController(sharedContext: sharedContext, state: signal)
    actions.present = { [weak controller] in controller?.present($0, in: .window(.root)) }
    actions.presentMenu = { [weak controller] in controller?.presentInGlobalOverlay($0, with: nil) }
    actions.reportNode = { [weak controller] id in
        return controller?.itemNode(forTag: CrashReportItemTag(id: id)) as? ItemListDisclosureItemNode
    }
    actions.push = { [weak controller] in (controller?.navigationController as? NavigationController)?.pushViewController($0) }
    actions.rootViewController = { [weak controller] in controller?.view.window?.rootViewController }
    return controller
}

private final class CrashReportTextController: ViewController {
    private let textView = UITextView()
    private let presentationData: PresentationData

    init(presentationData: PresentationData, text: String) {
        self.presentationData = presentationData
        super.init(navigationBarPresentationData: NavigationBarPresentationData(presentationData: presentationData))
                
        self.title = "Crash Log"
        self.textView.text = text
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadDisplayNode() {
        self.displayNode = ASDisplayNode()
        self.displayNode.backgroundColor = self.presentationData.theme.list.plainBackgroundColor
        self.textView.backgroundColor = .clear
        self.textView.textColor = self.presentationData.theme.list.itemPrimaryTextColor
        self.textView.font = .monospacedSystemFont(ofSize: 12.0, weight: .regular)
        self.textView.isEditable = false
        self.textView.alwaysBounceVertical = true
        self.textView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        self.textView.contentInsetAdjustmentBehavior = .never
        self.displayNode.view.addSubview(self.textView)
        self.displayNodeDidLoad()
    }
    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        let top = self.navigationLayout(layout: layout).navigationFrame.maxY
        self.textView.frame = CGRect(x: layout.safeInsets.left, y: top, width: layout.size.width - layout.safeInsets.left - layout.safeInsets.right, height: max(0, layout.size.height - top - layout.intrinsicInsets.bottom))
    }
}

/// Install only after the authorized root controller becomes ready. Storage and capture do not depend on this subscription.
public func setupCrashReportPrompt(context: AccountContext, isInternalBuild: Bool, navigationController: NavigationController, present: @escaping (ViewController) -> Void) -> Disposable {
    let actions = CrashReportActions(sharedContext: context.sharedContext, context: context)
    actions.present = present
    actions.push = { [weak navigationController] in navigationController?.pushViewController($0) }
    actions.rootViewController = { [weak navigationController] in navigationController?.view.window?.rootViewController }
    var didPresent = false
    weak var alert: ViewController?
    let disposable = (combineLatest(crashReportsSignal(), context.sharedContext.accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.experimentalUISettings]), context.sharedContext.applicationBindings.applicationIsActive, context.sharedContext.appLockContext.isPasscodeLocked)
    |> deliverOnMainQueue).start(next: { result, sharedData, active, locked in
        actions.canPresent = active && !locked
        guard active && !locked else {
            alert?.dismiss()
            return
        }
        let settings = sharedData.entries[ApplicationSpecificSharedDataKeys.experimentalUISettings]?.get(ExperimentalUISettings.self) ?? .defaultSettings
        guard !didPresent, crashReportAlertsEnabled(override: settings.showCrashReportAlerts, isInternalBuild: isInternalBuild), case let .success(reports) = result else { return }
        let pending = reports.filter { !$0.wasPresented }
        guard !pending.isEmpty else { return }
        didPresent = true
        let controller = textAlertController(sharedContext: context.sharedContext, title: "New Crash Log Available", text: "Nanogram closed unexpectedly. You can send the crash log to someone who can look at it.", actions: [
            TextAlertAction(type: .genericAction, title: "Not Now", action: {}),
            TextAlertAction(type: .defaultAction, title: "Send Log", action: {
                actions.send(pending[0])
            })
        ])
        alert = controller
        present(controller)
        crashReportWorkQueue.async {
            do {
                try CrashReportStore.shared.markPresented(ids: Set(pending.map(\.id)))
            } catch {
                // Keep the reports available; retrying the prompt next launch is preferable to losing diagnostics.
            }
        }
    })
    return ActionDisposable {
        disposable.dispose()
        Queue.mainQueue().async {
            actions.canPresent = false
            alert?.dismiss()
        }
    }
}
