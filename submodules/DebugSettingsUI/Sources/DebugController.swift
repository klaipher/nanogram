import Foundation
import DiskWriteAccounting
import UIKit
import Display
import SwiftSignalKit
import MediaCapabilities
import TelegramCore
import MtProtoKit
import MessageUI
import TelegramPresentationData
import TelegramUIPreferences
import ItemListUI
import PresentationDataUtils
import OverlayStatusController
import AccountContext
import AppBundle
import ZipArchive
import WebKit
import InAppPurchaseManager
import TelegramVoip
import ComponentFlow
import AlertComponent
import AlertCheckComponent
import WalletContext
import CpuProfiler
import CrashReporting
import ContextUI
import MessageWidget

private final class DebugControllerArguments {
    let sharedContext: SharedAccountContext
    let context: AccountContext?
    let presentController: (ViewController, ViewControllerPresentationArguments?) -> Void
    let pushController: (ViewController) -> Void
    let getRootController: () -> UIViewController?
    let getNavigationController: () -> NavigationController?
    var openLogs: () -> Void = {}
    
    init(sharedContext: SharedAccountContext, context: AccountContext?, presentController: @escaping (ViewController, ViewControllerPresentationArguments?) -> Void, pushController: @escaping (ViewController) -> Void, getRootController: @escaping () -> UIViewController?, getNavigationController: @escaping () -> NavigationController?) {
        self.sharedContext = sharedContext
        self.context = context
        self.presentController = presentController
        self.pushController = pushController
        self.getRootController = getRootController
        self.getNavigationController = getNavigationController
    }

    /// Where Debug Settings' log, report and diagnostics exports start (see `presentDebugLogExport`).
    var exportHost: DebugLogExportHost {
        return DebugLogExportHost(sharedContext: self.sharedContext, context: self.context, present: { [weak self] controller in
            self?.presentController(controller, nil)
        }, push: { [weak self] controller in
            self?.pushController(controller)
        }, rootViewController: { [weak self] in
            return self?.getRootController()
        })
    }
}

private extension ExperimentalUISettings.VideoMessageCameraMode {
    var debugTitle: String {
        switch self {
        case .legacy:
            return "Legacy"
        case .vga:
            return "VGA (640×480)"
        case .hdBilinear:
            return "HD · Bilinear"
        case .hdLanczos:
            return "HD · Lanczos"
        }
    }
}

private extension ExperimentalUISettings.RoundVideoCameraMatrix {
    var debugTitle: String {
        switch self {
        case .bt709:
            return "BT.709 (default)"
        case .cameraTag:
            return "Camera tag (old)"
        case .bt601:
            return "BT.601"
        }
    }
}

private extension ExperimentalUISettings.StickerRendererMode {
    var debugTitle: String {
        switch self {
        case .cpu:
            return "CPU"
        case .gpuLarge:
            return "GPU for large"
        case .gpuAll:
            return "GPU for all"
        }
    }
}

private enum DebugControllerItemTag: ItemListItemTag {
    case sendLogs

    func isEqual(to other: ItemListItemTag) -> Bool {
        return (other as? DebugControllerItemTag) == self
    }
}

private final class DebugLogsContextReferenceContentSource: ContextReferenceContentSource {
    private let sourceView: UIView

    init(sourceView: UIView) {
        self.sourceView = sourceView
    }

    func transitionInfo() -> ContextControllerReferenceViewInfo? {
        return ContextControllerReferenceViewInfo(referenceView: self.sourceView, contentAreaInScreenSpace: mainWindowScreenBounds, insets: UIEdgeInsets(top: -4.0, left: 0.0, bottom: -4.0, right: 0.0))
    }
}

/// The kinds the Send Logs menu offers. Each keeps its own file collection; where the files go is
/// `presentDebugLogExport`'s choice, the same for every kind.
private enum DebugLogAction {
    case sendLogs
    case sendShareLogs
    case sendGroupCallLogs
    case sendCallLogs
    case sendNotificationLogs
    case sendCriticalLogs
    case sendAllLogs
    case sendStorageStats

    var title: String {
        switch self {
        case .sendLogs: return "Logs"
        case .sendShareLogs: return "Share Logs"
        case .sendGroupCallLogs: return "Group Call Logs"
        case .sendCallLogs: return "Call Logs"
        case .sendNotificationLogs: return "Notification Logs"
        case .sendCriticalLogs: return "Critical Logs"
        case .sendAllLogs: return "All Logs"
        case .sendStorageStats: return "Storage Stats"
        }
    }

    var kind: DebugLogExportKind {
        switch self {
        case .sendLogs: return .logs
        case .sendShareLogs: return .shareLogs
        case .sendGroupCallLogs: return .groupCallLogs
        case .sendCallLogs: return .callLogs
        case .sendNotificationLogs: return .notificationLogs
        case .sendCriticalLogs: return .criticalLogs
        case .sendAllLogs: return .allLogs
        case .sendStorageStats: return .storageStats
        }
    }

    var textLayout: ContextMenuActionItemTextLayout {
        switch self {
        case .sendLogs, .sendShareLogs, .sendGroupCallLogs, .sendNotificationLogs:
            return .secondLineWithValue("Up to 40 MB")
        case .sendCallLogs:
            return .secondLineWithValue("Last 10 calls")
        case .sendCriticalLogs, .sendAllLogs, .sendStorageStats:
            return .singleLine
        }
    }

    func present(arguments: DebugControllerArguments) {
        presentDebugLogExport(host: arguments.exportHost, kind: self.kind, prepare: self.prepare(arguments: arguments))
    }

    private func prepare(arguments: DebugControllerArguments) -> (URL, DebugLogExportSpec) -> Signal<[DebugLogExportFile], NoError> {
        switch self {
        case .sendLogs:
            return debugLogConcatenatedArchiveSignal(Logger.shared.collectLogs(), additionalInfo: performanceExperimentsReport(modelIdentifier: debugDeviceModelIdentifier()) + "\n" + MediaCapabilities.shared.reportLines().joined(separator: "\n"))
        case .sendShareLogs:
            return debugLogConcatenatedArchiveSignal(Logger.shared.collectLogs(prefix: "/logs/share-logs"))
        case .sendGroupCallLogs:
            guard let context = arguments.context else {
                return { _, _ in .single([]) }
            }
            return debugLogConcatenatedArchiveSignal(Logger.shared.collectLogs(basePath: context.account.basePath + "/group-calls"))
        case .sendCallLogs:
            guard let context = arguments.context else {
                return { _, _ in .single([]) }
            }
            let path = callLogsPath(account: context.account)
            return debugLogFilesArchiveSignal(Signal { subscriber in
                subscriber.putNext(debugCallLogFiles(in: path, limit: 10))
                subscriber.putCompletion()
                return EmptyDisposable
            })
        case .sendNotificationLogs:
            let logsPath = arguments.sharedContext.basePath + "/logs/notification-logs"
            return debugLogConcatenatedArchiveSignal(Logger(rootPath: logsPath, basePath: logsPath).collectLogs())
        case .sendCriticalLogs:
            // The short log files, one attachment each.
            return { directory, spec in
                // The notification extension's own short log: it holds how a call ring started and ended.
                let notificationLogsPath = arguments.sharedContext.basePath + "/logs/notification-logs"
                let notificationLogs = Logger(rootPath: notificationLogsPath, basePath: notificationLogsPath).collectShortLogFiles()
                |> take(1)
                |> map { logs -> [(String, String)] in
                    return logs.map { ("nse-" + $0.0, $0.1) }
                }
                return combineLatest(Logger.shared.collectShortLogFiles() |> take(1), notificationLogs)
                |> take(1)
                |> deliverOn(debugLogExportPreparationQueue())
                |> map { appLogs, extensionLogs -> [DebugLogExportFile] in
                    return debugLogCopiedFiles(logs: appLogs + extensionLogs, baseName: spec.fileBaseName, mimeType: "text/plain", in: directory)
                }
            }
        case .sendAllLogs:
            // One text file per log type, zipped together.
            let logTypes: [String] = [
                "app-logs",
                "broadcast-logs",
                "siri-logs",
                "widget-logs",
                "notificationcontent-logs",
                "notification-logs"
            ]
            var logByType: [Signal<(type: String, logs: [(String, String)]), NoError>] = []
            for type in logTypes {
                let logsPath = arguments.sharedContext.basePath + "/logs/\(type)"
                logByType.append(Logger(rootPath: logsPath, basePath: logsPath).collectLogs()
                |> map { result -> (type: String, logs: [(String, String)]) in
                    return (type, result)
                })
            }
            return { directory, spec in
                return combineLatest(logByType)
                |> take(1)
                |> deliverOn(debugLogExportPreparationQueue())
                |> map { allLogs -> [DebugLogExportFile] in
                    var sources: [URL] = []
                    for (type, logItems) in allLogs {
                        let source = directory.appendingPathComponent("\(spec.fileBaseName)-\(type).txt")
                        if let _ = try? debugLogConcatenatedData(logs: logItems).write(to: source) {
                            sources.append(source)
                        }
                    }
                    return debugLogZip(sources: sources, baseName: spec.fileBaseName, in: directory).flatMap { [$0] } ?? []
                }
            }
        case .sendStorageStats:
            let containerPath = arguments.sharedContext.applicationBindings.containerPath
            return { directory, spec in
                return Signal { subscriber in
                    DispatchQueue.global().async {
                        let report = collectRawStorageUsageReport(containerPath: containerPath)
                        let target = directory.appendingPathComponent("\(spec.fileBaseName).txt")
                        if let _ = try? Data(report.utf8).write(to: target) {
                            subscriber.putNext([DebugLogExportFile(name: target.lastPathComponent, path: target.path, mimeType: "text/plain")])
                        } else {
                            subscriber.putNext([])
                        }
                        subscriber.putCompletion()
                    }
                    return EmptyDisposable
                }
            }
        }
    }
}

private func debugGroupNoiseModeTitle(_ mode: Int32) -> String {
    switch mode {
    case 1:
        return "WebRTC only"
    case 2:
        return "RNNoise only"
    default:
        return "Both"
    }
}

private enum DebugControllerSection: Int32 {
    case appInfo
    case logs
    case accounts
    case resetApp
    case sticker
    case experiments
    case streamsAndCalls
    case glassGroups
    case performance
    case performanceExperiments
    case translation
    case web
    case videoExperiments2
    case info
}

/// One switch of the "Glass groups" section: sets or clears `bit` in `glassDebugDisabledGroups`.
private func glassGroupSwitch(presentationData: ItemListPresentationData, arguments: DebugControllerArguments, sectionId: ItemListSectionId, title: String, text: String, bit: Int32, value: Bool) -> ListViewItem {
    return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: title, text: text, value: value, maximumNumberOfLines: 0, sectionId: sectionId, style: .blocks, updated: { value in
        let _ = updateExperimentalUISettingsInteractively(accountManager: arguments.sharedContext.accountManager, { settings in
            var settings = settings
            settings.glassDebugDisabledGroups = value ? (settings.glassDebugDisabledGroups | bit) : (settings.glassDebugDisabledGroups & ~bit)
            return settings
        }).start()
    })
}

enum DebugControllerEntry: ItemListNodeEntry {
    case logsHeader(PresentationTheme)
    case logsInfo(PresentationTheme)
    case resetAppHeader(PresentationTheme)
    case experimentsHeader(PresentationTheme)
    case sendReport
    case sendLogs(PresentationTheme)
    case logToFile(PresentationTheme, Bool)
    case logToConsole(PresentationTheme, Bool)
    case redactSensitiveData(PresentationTheme, Bool)
    case logNetworkDumps(PresentationTheme, Bool)
    case crashReports
    case keepChatNavigationStack(PresentationTheme, Bool)
    case skipReadHistory(PresentationTheme, Bool)
    case alwaysDisplayTyping(Bool)
    case crashOnSlowQueries(PresentationTheme, Bool)
    case crashOnMemoryPressure(PresentationTheme, Bool)
    case resetNotifications
    case resetDatabase(PresentationTheme)
    case resetDatabaseAndCache(PresentationTheme)
    case reindexUnread(PresentationTheme)
    case reindexCache
    case resetWebViewCache(PresentationTheme)
    case optimizeDatabase(PresentationTheme)
    case fakeGlass(Bool)
    case inputDecEngineEditor(Bool)
    case forceListViewImplChatBackend(Bool)
    case springSendAnimation(Bool)
    case fakeWalletTransfers(Bool)
    case stickerRendererMode(ExperimentalUISettings.StickerRendererMode)
    case disableImageContentAnalysis(Bool)
    case disableLanguageRecognition(Bool)
    case localTranscription(Bool)
    case enableVoipTcp(Bool)
    case coreListScrollTrace(Bool)
    case chatMediaEditorLegacy(Bool)
    case mediaGridLegacy(Bool)
    case sharedMediaGridLegacy(Bool)
    case storyLegacyVideoWriter(Bool)
    case chatLegacyVideoWriter(Bool)
    case chatSideListLegacy(Bool)
    case messageWidgets(Bool)
    case messageWidgetWallet(Bool)
    case stickerParallelQueues(Bool)
    case gifGridParallelDecode(Bool)
    case respectSystemMicrophone(Bool)
    case videoMessageCameraMode(ExperimentalUISettings.VideoMessageCameraMode)
    case videoMessageCloseFocus(Bool)
    case videoMessageCameraMatrix(ExperimentalUISettings.RoundVideoCameraMatrix)
    case compressedEmojiCache(Bool)
    case checkSerializedData(Bool)
    case enableQuickReactionSwitch(Bool)
    case liveStreamV2(Bool)
    case groupCallReferenceEngine(Bool)
    case callsHeader(PresentationTheme)
    case callsLivestreamHardwareDecoding(Bool)
    case callsNativeCapturePath(Bool)
    case callsSystemNoiseSuppression(Bool)
    case callsAdvancedDucking(Bool)
    case callsGroupNoiseMode(Int32)
    case callsThermalVideoLadder(Bool)
    case glassGroupsHeader(PresentationTheme)
    case glassGroupNavigationBar(Bool)
    case glassGroupInputPanel(Bool)
    case glassGroupFloatingButtons(Bool)
    case performanceHeader(PresentationTheme)
    case frameHitchLog(Bool)
    case nanogramGlanceables(Bool)
    case backSwipePreparePreviousScreen(Bool)
    case performanceExperimentsHeader(PresentationTheme)
    case performanceExperiment(PerformanceExperiment, Bool)
    case performanceExperimentsInfo(String)
    case enableNetworkFramework(Bool)
    case enableNetworkExperiments(Bool)
    case rustMTProtoEngine(Bool)
    case networkEngineInfo(String)
    case versionInfo(PresentationTheme)
    case collectCpuProfile
    case sendProfileLogs
    case sendMetricKitReports

    var section: ItemListSectionId {
        switch self {
        case .logsHeader, .logsInfo, .sendReport, .sendLogs:
            return DebugControllerSection.logs.rawValue
        case .crashReports:
            return DebugControllerSection.logs.rawValue
        case .logToFile, .logToConsole, .redactSensitiveData, .logNetworkDumps:
            return DebugControllerSection.logs.rawValue
        case .resetAppHeader, .resetDatabase, .resetDatabaseAndCache, .resetNotifications, .reindexUnread, .reindexCache, .optimizeDatabase:
            return DebugControllerSection.resetApp.rawValue
        case .resetWebViewCache:
            return DebugControllerSection.web.rawValue
        case .experimentsHeader, .keepChatNavigationStack, .skipReadHistory, .alwaysDisplayTyping, .crashOnSlowQueries, .crashOnMemoryPressure:
            return DebugControllerSection.experiments.rawValue
        case .compressedEmojiCache, .checkSerializedData, .enableQuickReactionSwitch, .fakeGlass, .inputDecEngineEditor, .forceListViewImplChatBackend, .coreListScrollTrace, .respectSystemMicrophone, .videoMessageCameraMode, .videoMessageCloseFocus, .videoMessageCameraMatrix, .liveStreamV2, .groupCallReferenceEngine:
            return DebugControllerSection.experiments.rawValue
        case .callsHeader, .callsLivestreamHardwareDecoding, .callsNativeCapturePath, .callsSystemNoiseSuppression, .callsAdvancedDucking, .callsGroupNoiseMode, .callsThermalVideoLadder:
            return DebugControllerSection.streamsAndCalls.rawValue
        case .glassGroupsHeader, .glassGroupNavigationBar, .glassGroupInputPanel, .glassGroupFloatingButtons:
            return DebugControllerSection.glassGroups.rawValue
        case .performanceHeader, .frameHitchLog, .nanogramGlanceables, .backSwipePreparePreviousScreen:
            return DebugControllerSection.performance.rawValue
        case .performanceExperimentsHeader, .performanceExperiment, .performanceExperimentsInfo:
            return DebugControllerSection.performanceExperiments.rawValue
        case .springSendAnimation, .fakeWalletTransfers, .stickerRendererMode, .disableImageContentAnalysis, .disableLanguageRecognition, .localTranscription, .enableVoipTcp, .chatMediaEditorLegacy, .mediaGridLegacy, .sharedMediaGridLegacy, .storyLegacyVideoWriter, .chatLegacyVideoWriter, .chatSideListLegacy, .messageWidgets, .messageWidgetWallet, .stickerParallelQueues, .gifGridParallelDecode:
            return DebugControllerSection.experiments.rawValue
        case .enableNetworkFramework, .enableNetworkExperiments, .rustMTProtoEngine, .networkEngineInfo:
            return DebugControllerSection.videoExperiments2.rawValue
        case .versionInfo:
            return DebugControllerSection.appInfo.rawValue
        case .collectCpuProfile, .sendProfileLogs, .sendMetricKitReports:
            return DebugControllerSection.logs.rawValue
        }
    }

    var stableId: Int {
        switch self {
        case .logsHeader:
            return -2
        case .logsInfo:
            return 15
        case .resetAppHeader:
            return 14
        case .experimentsHeader:
            return 17
        case .sendReport:
            return -1
        case .sendLogs:
            return 1
        case .logToFile:
            return 10
        case .logToConsole:
            return 11
        case .redactSensitiveData:
            return 12
        case .logNetworkDumps:
            return 13
        case .crashReports:
            return 2
        case .resetWebViewCache:
            return 71
        case .keepChatNavigationStack:
            return 18
        case .skipReadHistory:
            return 19
        case .alwaysDisplayTyping:
            return 20
        case .forceListViewImplChatBackend:
            return 22
        case .coreListScrollTrace:
            // Takes the id of the removed C++ Lottie renderer switch, right after `forceListViewImplChatBackend`.
            return 23
        case .respectSystemMicrophone:
            return 24
        case .videoMessageCameraMode:
            return 25
        case .videoMessageCloseFocus:
            // Appended right after `videoMessageCameraMode` (moved from 26 to 25 to make room); see the
            // ordering note at `springSendAnimation`.
            return 26
        case .videoMessageCameraMatrix:
            // Appended right after `videoMessageCloseFocus` (the two crash switches after it moved up by one
            // to make room); see the ordering note at `springSendAnimation`.
            return 27
        case .crashOnSlowQueries:
            return 28
        case .crashOnMemoryPressure:
            return 29
        case .resetNotifications:
            return 30
        case .resetDatabase:
            return 34
        case .resetDatabaseAndCache:
            return 35
        case .reindexUnread:
            return 38
        case .reindexCache:
            return 40
        case .optimizeDatabase:
            return 42
        case .fakeGlass:
            return 47
        case .inputDecEngineEditor:
            return 50
        case .compressedEmojiCache:
            // Appended right after `stickerRendererMode`, so the two GPU renderer settings sit
            // together; see the ordering note at `springSendAnimation`.
            return 76
        case .disableImageContentAnalysis:
            // Appended right after `compressedEmojiCache`, then the next three in this order.
            return 77
        case .disableLanguageRecognition:
            return 78
        case .localTranscription:
            return 79
        case .enableVoipTcp:
            return 80
        case .chatMediaEditorLegacy:
            // Appended right after `enableVoipTcp` (81, retired, was the iPad display-link cap), in this order; see the ordering note at `springSendAnimation`.
            return 82
        case .mediaGridLegacy:
            // Appended right after `enableVoipTcp` (81, retired, was the iPad display-link cap), in this order; see the ordering note at `springSendAnimation`.
            return 83
        case .sharedMediaGridLegacy:
            // Appended right after `enableVoipTcp` (81, retired, was the iPad display-link cap), in this order; see the ordering note at `springSendAnimation`.
            return 84
        case .storyLegacyVideoWriter:
            // Appended right after `enableVoipTcp` (81, retired, was the iPad display-link cap), in this order; see the ordering note at `springSendAnimation`.
            return 85
        case .chatLegacyVideoWriter:
            // Appended right after `enableVoipTcp` (81, retired, was the iPad display-link cap), in this order; see the ordering note at `springSendAnimation`.
            return 86
        case .chatSideListLegacy:
            // Appended right after `enableVoipTcp` (81, retired, was the iPad display-link cap), in this order; see the ordering note at `springSendAnimation`.
            return 87
        case .messageWidgets:
            // Appended right after `chatSideListLegacy`; see the ordering note at `springSendAnimation`.
            return 88
        case .messageWidgetWallet:
            return 89
        case .stickerParallelQueues:
            // Appended after `messageWidgetWallet`; see the ordering note at `springSendAnimation`.
            return 150
        case .gifGridParallelDecode:
            return 151
        case .checkSerializedData:
            return 58
        case .enableQuickReactionSwitch:
            return 59
        case .liveStreamV2:
            return 60
        case .groupCallReferenceEngine:
            return 62
        case .callsHeader:
            // The "Streams & Calls" section is its own section, so these ids only order it inside itself.
            return 90
        case .callsLivestreamHardwareDecoding:
            return 91
        case .callsNativeCapturePath:
            return 92
        case .callsSystemNoiseSuppression:
            return 93
        case .callsAdvancedDucking:
            return 94
        case .callsGroupNoiseMode:
            return 95
        case .callsThermalVideoLadder:
            return 97
        case .glassGroupsHeader:
            // Its own section, so these ids only order it inside itself.
            return 120
        case .glassGroupNavigationBar:
            return 121
        case .glassGroupInputPanel:
            return 122
        case .glassGroupFloatingButtons:
            return 123
        case .performanceHeader:
            // Its own section, so these ids only order it inside itself (ids of retired switches are not reused).
            return 137
        case .frameHitchLog:
            // Kept its id when the switches between it and the header were retired; see the ordering note at `springSendAnimation`.
            return 143
        case .nanogramGlanceables:
            return 145
        case .backSwipePreparePreviousScreen:
            // Kept its id when the switches before it were retired; see the ordering note at `springSendAnimation`.
            return 148
        case .performanceExperimentsHeader:
            // Its own section, appended right after PERFORMANCE.
            return 160
        case let .performanceExperiment(experiment, _):
            switch experiment {
            case .threadPoolQualityOfService:
                return 161
            case .softwareDecodeThreads:
                return 162
            case .previewHardwareDecode:
                return 163
            }
        case .performanceExperimentsInfo:
            return 164
        case .springSendAnimation:
            // ItemList asserts its entries are in strictly increasing order (`<`: section, then
            // `sortIndex`, which is the stableId here; ItemListControllerNode.swift), so an id must
            // match the position the entry is appended at, or the list traps at runtime inside its
            // own state closure. DebugControllerEntriesTests checks this for every combination.
            return 73
        case .fakeWalletTransfers:
            // Appended right after `springSendAnimation`; see the ordering note above.
            return 74
        case .stickerRendererMode:
            // Appended right after `fakeWalletTransfers`; see the ordering note above.
            return 75
        case .enableNetworkFramework:
            return 105
        case .enableNetworkExperiments:
            return 106
        case .rustMTProtoEngine:
            return 107
        case .networkEngineInfo:
            return 108
        case .versionInfo:
            return -4
        case .collectCpuProfile:
            return 111
        case .sendProfileLogs:
            return 112
        case .sendMetricKitReports:
            return 113
        }
    }

    private var sortIndex: Int {
        switch self {
        case .sendMetricKitReports: return 3
        case .sendProfileLogs: return 4
        case .collectCpuProfile: return 5
        case .resetAppHeader: return 0
        case .resetDatabase: return 2
        case .resetDatabaseAndCache: return 3
        case .resetNotifications: return 4
        case .reindexUnread: return 8
        case .reindexCache: return 10
        case .optimizeDatabase: return 11
        default: return self.stableId
        }
    }

    static func <(lhs: DebugControllerEntry, rhs: DebugControllerEntry) -> Bool {
        if lhs.section != rhs.section {
            return lhs.section < rhs.section
        }
        return lhs.sortIndex < rhs.sortIndex
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! DebugControllerArguments
        switch self {
        case .logsHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "LOGS", sectionId: self.section)
        case .logsInfo:
            return ItemListTextItem(presentationData: presentationData, text: .plain("When enabled, your message text and other sensitive information are excluded from logs."), sectionId: self.section)
        case .resetAppHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "RESET APP", sectionId: self.section)
        case .experimentsHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "EXPERIMENTAL SETTINGS", sectionId: self.section)
        case .callsHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "STREAMS & CALLS", sectionId: self.section)
        case .glassGroupsHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "GLASS GROUPS (GPU ATTRIBUTION)", sectionId: self.section)
        case let .glassGroupNavigationBar(value):
            return glassGroupSwitch(presentationData: presentationData, arguments: arguments, sectionId: self.section, title: "Navigation bar glass off", text: "Replaces the navigation bar's glass with a solid fill, to measure what it costs. Default: off. Applies at once.", bit: ExperimentalUISettings.glassDebugNavigationBar, value: value)
        case let .glassGroupInputPanel(value):
            return glassGroupSwitch(presentationData: presentationData, arguments: arguments, sectionId: self.section, title: "Input panel glass off", text: "Replaces the chat input panel's glass with a solid fill. Default: off. Applies at once.", bit: ExperimentalUISettings.glassDebugInputPanel, value: value)
        case let .glassGroupFloatingButtons(value):
            return glassGroupSwitch(presentationData: presentationData, arguments: arguments, sectionId: self.section, title: "Floating buttons glass off", text: "Replaces the scroll-to-bottom, mentions and reactions buttons' glass with a solid fill. Default: off. Applies at once.", bit: ExperimentalUISettings.glassDebugFloatingButtons, value: value)
        case .performanceHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "PERFORMANCE", sectionId: self.section)
        case let .nanogramGlanceables(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Glanceables: widgets, Live Activities, Shortcuts", text: "Turns on the chats widget (small and Lock Screen), the Saved Messages control, Live Activities for live location and calls without CallKit, and the Shortcuts actions. Chat names show only while the app is unlocked and, on the Lock Screen, only if names are allowed in notification settings. Default: off.", value: value, maximumNumberOfLines: 0, sectionId: self.section, style: .blocks, updated: { value in
                let _ = updateExperimentalUISettingsInteractively(accountManager: arguments.sharedContext.accountManager, { settings in
                    var settings = settings
                    settings.nanogramGlanceables = value
                    return settings
                }).start()
            })
        case let .frameHitchLog(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Frame hitches: log with main-thread stacks", text: "While you scroll a chat, the chat list or any list, and while the keyboard opens or closes, every frame is timed. One \"Frame hitches\" line per scroll or keyboard animation (frames, hitches, hitch time, longest gap), followed by what the main thread was doing during its longest stalls (\"Frame hitch stack\"). Holds the screen at its top rate and samples the main thread while measuring, so use it only to collect logs. Turns itself off after 30 minutes and when the app goes to the background. Needs Log to File; send with Send Logs. Default: off.", value: value, maximumNumberOfLines: 0, sectionId: self.section, style: .blocks, updated: { value in
                let _ = updateExperimentalUISettingsInteractively(accountManager: arguments.sharedContext.accountManager, { settings in
                    var settings = settings
                    settings.frameHitchLog = value
                    return settings
                }).start()
            })
        case let .backSwipePreparePreviousScreen(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Back swipe: prepare the previous screen", text: "On (default): while a screen sits idle, the screen beneath it is laid out and drawn out of sight, so the swipe starts faster. Off: the swipe back lays out and draws the screen beneath when your finger goes down, as Telegram does. Costs the memory of one extra drawn screen (freed on a memory warning) and a short main-thread job about half a second after a screen settles.", value: value, maximumNumberOfLines: 0, sectionId: self.section, style: .blocks, updated: { value in
                let _ = updateExperimentalUISettingsInteractively(accountManager: arguments.sharedContext.accountManager, { settings in
                    var settings = settings
                    settings.backSwipePreparePreviousScreen = value
                    return settings
                }).start()
            })
        case .sendReport:
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: "Send Report", kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                presentDebugLogExport(host: arguments.exportHost, kind: .report, prepare: debugReportPrepare(sharedContext: arguments.sharedContext, context: arguments.context))
            })
        case .sendLogs:
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: "Send Logs (developer)", kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.openLogs()
            }, tag: DebugControllerItemTag.sendLogs)
        case let .logToFile(_, value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Log to File", value: value, sectionId: self.section, style: .blocks, updated: { value in
                let _ = updateLoggingSettings(accountManager: arguments.sharedContext.accountManager, {
                    $0.withUpdatedLogToFile(value)
                }).start()
            })
        case let .logToConsole(_, value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Log to Console", value: value, sectionId: self.section, style: .blocks, updated: { value in
                let _ = updateLoggingSettings(accountManager: arguments.sharedContext.accountManager, {
                    $0.withUpdatedLogToConsole(value)
                }).start()
            })
        case .crashReports:
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: "Crash Logs", label: "", sectionId: self.section, style: .blocks, action: {
                arguments.pushController(crashReportsController(sharedContext: arguments.sharedContext, context: arguments.context))
            })
        case let .redactSensitiveData(_, value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Remove Sensitive Data", value: value, sectionId: self.section, style: .blocks, updated: { value in
                let _ = updateLoggingSettings(accountManager: arguments.sharedContext.accountManager, {
                    $0.withUpdatedRedactSensitiveData(value)
                }).start()
            })
        case let .logNetworkDumps(_, value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Network protocol dumps", value: value, sectionId: self.section, style: .blocks, updated: { value in
                let _ = updateLoggingSettings(accountManager: arguments.sharedContext.accountManager, {
                    $0.withUpdatedLogNetworkDumps(value)
                }).start()
            })
        case let .keepChatNavigationStack(_, value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Keep Chat Stack", value: value, sectionId: self.section, style: .blocks, updated: { value in
                let _ = updateExperimentalUISettingsInteractively(accountManager: arguments.sharedContext.accountManager, { settings in
                    var settings = settings
                    settings.keepChatNavigationStack = value
                    return settings
                }).start()
            })
        case let .skipReadHistory(_, value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Skip read history", value: value, sectionId: self.section, style: .blocks, updated: { value in
                let _ = updateExperimentalUISettingsInteractively(accountManager: arguments.sharedContext.accountManager, { settings in
                    var settings = settings
                    settings.skipReadHistory = value
                    return settings
                }).start()
            })
        case let .alwaysDisplayTyping(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Show Typing", value: value, sectionId: self.section, style: .blocks, updated: { value in
                let _ = updateExperimentalUISettingsInteractively(accountManager: arguments.sharedContext.accountManager, { settings in
                    var settings = settings
                    settings.alwaysDisplayTyping = value
                    return settings
                }).start()
            })
        case let .crashOnSlowQueries(_, value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Crash when slow", value: value, sectionId: self.section, style: .blocks, updated: { value in
                let _ = updateExperimentalUISettingsInteractively(accountManager: arguments.sharedContext.accountManager, { settings in
                    var settings = settings
                    settings.crashOnLongQueries = value
                    return settings
                }).start()
            })
        case let .crashOnMemoryPressure(_, value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Memory overlay (MB in the corner)", value: value, sectionId: self.section, style: .blocks, updated: { value in
                let _ = updateExperimentalUISettingsInteractively(accountManager: arguments.sharedContext.accountManager, { settings in
                    var settings = settings
                    settings.crashOnMemoryPressure = value
                    return settings
                }).start()
            })
        case .resetNotifications:
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: "Reset Notifications", kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                UIApplication.shared.unregisterForRemoteNotifications()
                
                if let context = arguments.context {
                    let controller = textAlertController(context: context, title: nil, text: "Now restart the app", actions: [TextAlertAction(type: .genericAction, title: "OK", action: {})])
                    arguments.presentController(controller, nil)
                }
            })
        case .resetDatabase:
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: "Clear Database", kind: .destructive, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                guard let context = arguments.context else {
                    return
                }
                let presentationData = arguments.sharedContext.currentPresentationData.with { $0 }
                let actionSheet = ActionSheetController(presentationData: presentationData)
                actionSheet.setItemGroups([ActionSheetItemGroup(items: [
                    ActionSheetTextItem(title: "All secret chats will be lost."),
                    ActionSheetButtonItem(title: "Clear Database", color: .destructive, action: { [weak actionSheet] in
                        actionSheet?.dismissAnimated()
                        let databasePath = context.account.basePath + "/postbox/db"
                        let _ = try? FileManager.default.removeItem(atPath: databasePath)
                        exit(0)
                    }),
                    ]), ActionSheetItemGroup(items: [
                        ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                            actionSheet?.dismissAnimated()
                        })
                    ])])
                arguments.presentController(actionSheet, nil)
            })
        case .resetDatabaseAndCache:
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: "Clear Database and Cache", kind: .destructive, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                guard let context = arguments.context else {
                    return
                }
                let presentationData = arguments.sharedContext.currentPresentationData.with { $0 }
                let actionSheet = ActionSheetController(presentationData: presentationData)
                actionSheet.setItemGroups([ActionSheetItemGroup(items: [
                    ActionSheetTextItem(title: "All secret chats will be lost."),
                    ActionSheetButtonItem(title: "Clear Database", color: .destructive, action: { [weak actionSheet] in
                        actionSheet?.dismissAnimated()
                        let databasePath = context.account.basePath + "/postbox"
                        let _ = try? FileManager.default.removeItem(atPath: databasePath)
                        exit(0)
                    }),
                    ]), ActionSheetItemGroup(items: [
                        ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                            actionSheet?.dismissAnimated()
                        })
                    ])])
                arguments.presentController(actionSheet, nil)
            })
        case .reindexUnread:
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: "Reindex Unread Counters", kind: .destructive, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                guard let context = arguments.context else {
                    return
                }
                let presentationData = arguments.sharedContext.currentPresentationData.with { $0 }
                let controller = OverlayStatusController(theme: presentationData.theme, type: .loading(cancelled: nil))
                arguments.presentController(controller, nil)
                let _ = (context.engine.messages.debugReindexUnreadCounters()
                |> deliverOnMainQueue).start(completed: {
                    controller.dismiss()
                })
            })
        case .reindexCache:
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: "Reindex Cache", kind: .destructive, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                guard let context = arguments.context else {
                    return
                }
                
                var signal = context.engine.resources.reindexCacheInBackground(lowImpact: false)
                
                var cancelImpl: (() -> Void)?
                let presentationData = context.sharedContext.currentPresentationData.with { $0 }
                let progressSignal = Signal<Never, NoError> { subscriber in
                    let controller = OverlayStatusController(theme: presentationData.theme, type: .loading(cancelled: {
                        cancelImpl?()
                    }))
                    arguments.presentController(controller, nil)
                    return ActionDisposable { [weak controller] in
                        Queue.mainQueue().async() {
                            controller?.dismiss()
                        }
                    }
                }
                |> runOn(Queue.mainQueue())
                |> delay(0.15, queue: Queue.mainQueue())
                let progressDisposable = progressSignal.start()
                
                let reindexDisposable = MetaDisposable()
                
                signal = signal
                |> afterDisposed {
                    Queue.mainQueue().async {
                        progressDisposable.dispose()
                    }
                }
                cancelImpl = {
                    reindexDisposable.set(nil)
                }
                reindexDisposable.set((signal
                |> deliverOnMainQueue).start(completed: {
                }))
            })
        case .resetWebViewCache:
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: "Clear Web View Cache", kind: .destructive, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                WKWebsiteDataStore.default().removeData(ofTypes: [
                    WKWebsiteDataTypeDiskCache,
                    WKWebsiteDataTypeOfflineWebApplicationCache,
                    WKWebsiteDataTypeMemoryCache,
                    WKWebsiteDataTypeLocalStorage,
                    WKWebsiteDataTypeCookies,
                    WKWebsiteDataTypeSessionStorage,
                    WKWebsiteDataTypeIndexedDBDatabases,
                    WKWebsiteDataTypeWebSQLDatabases,
                    WKWebsiteDataTypeFetchCache,
                    WKWebsiteDataTypeServiceWorkerRegistrations
                ], modifiedSince: Date(timeIntervalSince1970: 0), completionHandler:{ })
            })
        case .optimizeDatabase:
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: "Optimize Database", kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                guard let context = arguments.context else {
                    return
                }
                let presentationData = arguments.sharedContext.currentPresentationData.with { $0 }
                let controller = OverlayStatusController(theme: presentationData.theme, type: .loading(cancelled: nil))
                arguments.presentController(controller, nil)
                let _ = (context.account.postbox.optimizeStorage()
                |> deliverOnMainQueue).start(completed: {
                    controller.dismiss()
                    
                    let controller = OverlayStatusController(theme: presentationData.theme, type: .success)
                    arguments.presentController(controller, nil)
                })
            })
        case let .fakeGlass(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Fake glass", value: value, sectionId: self.section, style: .blocks, updated: { value in
                let _ = arguments.sharedContext.accountManager.transaction ({ transaction in
                    transaction.updateSharedData(ApplicationSpecificSharedDataKeys.experimentalUISettings, { settings in
                        var settings = settings?.get(ExperimentalUISettings.self) ?? ExperimentalUISettings.defaultSettings
                        settings.fakeGlass = value
                        return EnginePreferencesEntry(settings)
                    })
                }).start()
            })
        case let .inputDecEngineEditor(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Input V3", value: value, sectionId: self.section, style: .blocks, updated: { value in
                let _ = arguments.sharedContext.accountManager.transaction ({ transaction in
                    transaction.updateSharedData(ApplicationSpecificSharedDataKeys.experimentalUISettings, { settings in
                        var settings = settings?.get(ExperimentalUISettings.self) ?? ExperimentalUISettings.defaultSettings
                        settings.useInputDecEngine = value
                        return EnginePreferencesEntry(settings)
                    })
                }).start()
            })
        case let .forceListViewImplChatBackend(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Chat: old list (ListViewImpl)", value: value, sectionId: self.section, style: .blocks, updated: { value in
                let _ = arguments.sharedContext.accountManager.transaction ({ transaction in
                    transaction.updateSharedData(ApplicationSpecificSharedDataKeys.experimentalUISettings, { settings in
                        var settings = settings?.get(ExperimentalUISettings.self) ?? ExperimentalUISettings.defaultSettings
                        settings.forceListViewImplChatBackend = value
                        return EnginePreferencesEntry(settings)
                    })
                }).start()
            })
        case let .springSendAnimation(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Chat: spring send animation", value: value, sectionId: self.section, style: .blocks, updated: { value in
                let _ = arguments.sharedContext.accountManager.transaction ({ transaction in
                    transaction.updateSharedData(ApplicationSpecificSharedDataKeys.experimentalUISettings, { settings in
                        var settings = settings?.get(ExperimentalUISettings.self) ?? ExperimentalUISettings.defaultSettings
                        settings.springSendAnimation = value
                        return EnginePreferencesEntry(settings)
                    })
                }).start()
            })
        case let .fakeWalletTransfers(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Wallet: fake transfers", value: value, sectionId: self.section, style: .blocks, updated: { value in
                let _ = arguments.sharedContext.accountManager.transaction ({ transaction in
                    transaction.updateSharedData(ApplicationSpecificSharedDataKeys.experimentalUISettings, { settings in
                        var settings = settings?.get(ExperimentalUISettings.self) ?? ExperimentalUISettings.defaultSettings
                        settings.fakeWalletTransfers = value
                        return EnginePreferencesEntry(settings)
                    })
                }).start()
            })
        case let .coreListScrollTrace(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Chat: CoreList scroll trace", value: value, sectionId: self.section, style: .blocks, updated: { value in
                let _ = updateExperimentalUISettingsInteractively(accountManager: arguments.sharedContext.accountManager, { settings in
                    var settings = settings
                    settings.coreListScrollTrace = value
                    return settings
                }).start()
            })
        case let .respectSystemMicrophone(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Recording: respect system microphone", value: value, sectionId: self.section, style: .blocks, updated: { value in
                let _ = arguments.sharedContext.accountManager.transaction ({ transaction in
                    transaction.updateSharedData(ApplicationSpecificSharedDataKeys.experimentalUISettings, { settings in
                        var settings = settings?.get(ExperimentalUISettings.self) ?? ExperimentalUISettings.defaultSettings
                        settings.respectSystemMicrophone = value
                        return EnginePreferencesEntry(settings)
                    })
                }).start()
            })
        case let .videoMessageCloseFocus(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Circle Close Focus (Macro)", text: "Back camera switches to the ultra-wide for close subjects (Modern pipeline). Reopen the camera to apply.", value: value, sectionId: self.section, style: .blocks, updated: { value in
                let _ = updateExperimentalUISettingsInteractively(accountManager: arguments.sharedContext.accountManager, { settings in
                    var settings = settings
                    settings.videoMessageCloseFocus = value
                    return settings
                }).start()
            })
        case let .videoMessageCameraMatrix(value):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: "Circle Colour Decode", label: value.debugTitle, sectionId: self.section, style: .blocks, action: {
                let presentationData = arguments.sharedContext.currentPresentationData.with { $0 }
                let actionSheet = ActionSheetController(presentationData: presentationData)
                var items: [ActionSheetItem] = [
                    ActionSheetTextItem(title: "The YCbCr matrix the Modern pipeline decodes the camera's frames with. The camera tags them BT.601; BT.709 matches Legacy and the official app. Reopen the circle camera to apply.")
                ]
                for matrix in ExperimentalUISettings.RoundVideoCameraMatrix.allCases {
                    items.append(ActionSheetButtonItem(title: matrix.debugTitle, color: .accent, action: { [weak actionSheet] in
                        actionSheet?.dismissAnimated()
                        let _ = updateExperimentalUISettingsInteractively(accountManager: arguments.sharedContext.accountManager, { settings in
                            var settings = settings
                            settings.videoMessageCameraMatrix = matrix
                            return settings
                        }).start()
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
                arguments.presentController(actionSheet, nil)
            })
        case let .videoMessageCameraMode(value):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: "Video Message Camera", label: value.debugTitle, sectionId: self.section, style: .blocks, action: {
                let presentationData = arguments.sharedContext.currentPresentationData.with { $0 }
                let actionSheet = ActionSheetController(presentationData: presentationData)
                var items: [ActionSheetItem] = [
                    ActionSheetTextItem(title: "Reopen the camera to apply. VGA and HD use the Modern Video Message Pipeline and record 480×480 at 30 FPS.")
                ]
                for mode in ExperimentalUISettings.VideoMessageCameraMode.allCases {
                    items.append(ActionSheetButtonItem(title: mode.debugTitle, color: .accent, action: { [weak actionSheet] in
                        actionSheet?.dismissAnimated()
                        let _ = updateExperimentalUISettingsInteractively(accountManager: arguments.sharedContext.accountManager, { settings in
                            var settings = settings
                            // nil, not true, for the modern modes: an explicit value would override the
                            // server killswitch (ios_killswitch_disable_neo_round_camera_v2) for good.
                            settings.useModernVideoMessagePipeline = mode == .legacy ? false : nil
                            settings.videoMessageCameraMode = mode
                            return settings
                        }).start()
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
                arguments.presentController(actionSheet, nil)
            })
        case let .stickerRendererMode(value):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: "Stickers: renderer", label: value.debugTitle, sectionId: self.section, style: .blocks, action: {
                let presentationData = arguments.sharedContext.currentPresentationData.with { $0 }
                let actionSheet = ActionSheetController(presentationData: presentationData)
                var items: [ActionSheetItem] = [
                    ActionSheetTextItem(title: "Reopen open chats to apply. GPU renders animated stickers with Metal from a separate DCT frame cache; \"large\" means at least 200×200 pixels (chat stickers and previews, not panels or emoji).")
                ]
                for mode in ExperimentalUISettings.StickerRendererMode.allCases {
                    items.append(ActionSheetButtonItem(title: mode.debugTitle, color: .accent, action: { [weak actionSheet] in
                        actionSheet?.dismissAnimated()
                        let _ = updateExperimentalUISettingsInteractively(accountManager: arguments.sharedContext.accountManager, { settings in
                            var settings = settings
                            settings.stickerRendererMode = mode
                            return settings
                        }).start()
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
                arguments.presentController(actionSheet, nil)
            })
        case let .compressedEmojiCache(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Emoji: GPU renderer (YUVA)", value: value, sectionId: self.section, style: .blocks, updated: { value in
                let _ = arguments.sharedContext.accountManager.transaction ({ transaction in
                    transaction.updateSharedData(ApplicationSpecificSharedDataKeys.experimentalUISettings, { settings in
                        var settings = settings?.get(ExperimentalUISettings.self) ?? ExperimentalUISettings.defaultSettings
                        settings.compressedEmojiCache = value
                        return EnginePreferencesEntry(settings)
                    })
                }).start()
            })
        case let .disableImageContentAnalysis(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Photos: skip text and QR recognition", value: value, sectionId: self.section, style: .blocks, updated: { value in
                let _ = updateExperimentalUISettingsInteractively(accountManager: arguments.sharedContext.accountManager, { settings in
                    var settings = settings
                    settings.disableImageContentAnalysis = value
                    return settings
                }).start()
            })
        case let .disableLanguageRecognition(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Translate: skip language detection", value: value, sectionId: self.section, style: .blocks, updated: { value in
                let _ = updateExperimentalUISettingsInteractively(accountManager: arguments.sharedContext.accountManager, { settings in
                    var settings = settings
                    settings.disableLanguageRecognition = value
                    return settings
                }).start()
            })
        case let .localTranscription(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Voice messages: on-device transcription", value: value, maximumNumberOfLines: 2, sectionId: self.section, style: .blocks, updated: { value in
                let _ = updateExperimentalUISettingsInteractively(accountManager: arguments.sharedContext.accountManager, { settings in
                    var settings = settings
                    settings.localTranscription = value
                    return settings
                }).start()
            })
        case let .enableVoipTcp(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Calls: allow TCP fallback", value: value, maximumNumberOfLines: 2, sectionId: self.section, style: .blocks, updated: { value in
                let _ = updateExperimentalUISettingsInteractively(accountManager: arguments.sharedContext.accountManager, { settings in
                    var settings = settings
                    settings.enableVoipTcp = value
                    return settings
                }).start()
            })
        case let .messageWidgets(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Message widgets", text: "A bot's widget in a message runs its own script in this app as soon as the chat shows it. Off by default: Telegram 13.2's widget engine has a published remote code execution (tg-widget-rce). Off (or in Lockdown Mode) a widget message shows the unsupported-content pill and runs nothing. Turning it on forgets widgets stopped after a crash.", value: value, maximumNumberOfLines: 0, sectionId: self.section, style: .blocks, updated: { value in
                MessageWidgetLocalSettings.setWidgetsEnabled(value)
            })
        case let .messageWidgetWallet(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Message widgets: wallet", text: "Lets a widget ask the wallet to pay or sign. Off until the path has been tested on a device with a funded test wallet.", value: value, maximumNumberOfLines: 0, sectionId: self.section, style: .blocks, updated: { value in
                MessageWidgetLocalSettings.setWalletEnabled(value)
            })
        case let .chatMediaEditorLegacy(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Chat: legacy media editor", value: value, sectionId: self.section, style: .blocks, updated: { value in
                let _ = updateExperimentalUISettingsInteractively(accountManager: arguments.sharedContext.accountManager, { settings in
                    var settings = settings
                    settings.chatMediaEditorLegacy = value
                    return settings
                }).start()
            })
        case let .mediaGridLegacy(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Media picker: legacy grid", value: value, sectionId: self.section, style: .blocks, updated: { value in
                let _ = updateExperimentalUISettingsInteractively(accountManager: arguments.sharedContext.accountManager, { settings in
                    var settings = settings
                    settings.mediaGridLegacy = value
                    return settings
                }).start()
            })
        case let .sharedMediaGridLegacy(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Shared media: legacy grid", value: value, sectionId: self.section, style: .blocks, updated: { value in
                let _ = updateExperimentalUISettingsInteractively(accountManager: arguments.sharedContext.accountManager, { settings in
                    var settings = settings
                    settings.sharedMediaGridLegacy = value
                    return settings
                }).start()
            })
        case let .storyLegacyVideoWriter(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Stories: legacy video writer", value: value, sectionId: self.section, style: .blocks, updated: { value in
                let _ = updateExperimentalUISettingsInteractively(accountManager: arguments.sharedContext.accountManager, { settings in
                    var settings = settings
                    settings.storyLegacyVideoWriter = value
                    return settings
                }).start()
            })
        case let .chatLegacyVideoWriter(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Chat videos: legacy video writer", value: value, sectionId: self.section, style: .blocks, updated: { value in
                let _ = updateExperimentalUISettingsInteractively(accountManager: arguments.sharedContext.accountManager, { settings in
                    var settings = settings
                    settings.chatLegacyVideoWriter = value
                    return settings
                }).start()
            })
        case let .stickerParallelQueues(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Stickers: parallel queues", value: value, sectionId: self.section, style: .blocks, updated: { value in
                let _ = updateExperimentalUISettingsInteractively(accountManager: arguments.sharedContext.accountManager, { settings in
                    var settings = settings
                    settings.stickerParallelQueues = value
                    return settings
                }).start()
            })
        case let .gifGridParallelDecode(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "GIF grid: parallel decode", value: value, sectionId: self.section, style: .blocks, updated: { value in
                let _ = updateExperimentalUISettingsInteractively(accountManager: arguments.sharedContext.accountManager, { settings in
                    var settings = settings
                    settings.gifGridParallelDecode = value
                    return settings
                }).start()
            })
        case let .chatSideListLegacy(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Chat side list: legacy strip", value: value, sectionId: self.section, style: .blocks, updated: { value in
                let _ = updateExperimentalUISettingsInteractively(accountManager: arguments.sharedContext.accountManager, { settings in
                    var settings = settings
                    settings.chatSideListLegacy = value
                    return settings
                }).start()
            })
        case let .checkSerializedData(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Check Serialized Data", value: value, sectionId: self.section, style: .blocks, updated: { value in
                let _ = arguments.sharedContext.accountManager.transaction ({ transaction in
                    transaction.updateSharedData(ApplicationSpecificSharedDataKeys.experimentalUISettings, { settings in
                        var settings = settings?.get(ExperimentalUISettings.self) ?? ExperimentalUISettings.defaultSettings
                        settings.checkSerializedData = value
                        return EnginePreferencesEntry(settings)
                    })
                }).start()
            })
        case let .enableQuickReactionSwitch(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Enable Quick Reaction", value: value, sectionId: self.section, style: .blocks, updated: { value in
                let _ = arguments.sharedContext.accountManager.transaction ({ transaction in
                    transaction.updateSharedData(ApplicationSpecificSharedDataKeys.experimentalUISettings, { settings in
                        var settings = settings?.get(ExperimentalUISettings.self) ?? ExperimentalUISettings.defaultSettings
                        settings.disableQuickReaction = !value
                        return EnginePreferencesEntry(settings)
                    })
                }).start()
            })
        case let .liveStreamV2(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Live Stream V2", value: value, sectionId: self.section, style: .blocks, updated: { value in
                let _ = arguments.sharedContext.accountManager.transaction ({ transaction in
                    transaction.updateSharedData(ApplicationSpecificSharedDataKeys.experimentalUISettings, { settings in
                        var settings = settings?.get(ExperimentalUISettings.self) ?? ExperimentalUISettings.defaultSettings
                        settings.liveStreamV2 = value
                        return EnginePreferencesEntry(settings)
                    })
                }).start()
            })
        case let .groupCallReferenceEngine(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Group calls: reference engine", value: value, sectionId: self.section, style: .blocks, updated: { value in
                let _ = arguments.sharedContext.accountManager.transaction ({ transaction in
                    transaction.updateSharedData(ApplicationSpecificSharedDataKeys.experimentalUISettings, { settings in
                        var settings = settings?.get(ExperimentalUISettings.self) ?? ExperimentalUISettings.defaultSettings
                        settings.groupCallReferenceEngine = value
                        return EnginePreferencesEntry(settings)
                    })
                }).start()
            })
        case let .callsLivestreamHardwareDecoding(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Livestream hardware decoding", text: "Decodes live stream video with the video chip instead of the CPU. Falls back to the CPU on any error. Default: on. Applies to the next stream.", value: value, maximumNumberOfLines: 0, sectionId: self.section, style: .blocks, updated: { value in
                let _ = updateExperimentalUISettingsInteractively(accountManager: arguments.sharedContext.accountManager, { settings in
                    var settings = settings
                    settings.callsLivestreamHardwareDecoding = value
                    return settings
                }).start()
            })
        case let .callsNativeCapturePath(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Native camera frames", text: "Camera frames go to the encoder without a CPU colour conversion. Default: on. Applies to the next camera start.", value: value, maximumNumberOfLines: 0, sectionId: self.section, style: .blocks, updated: { value in
                let _ = updateExperimentalUISettingsInteractively(accountManager: arguments.sharedContext.accountManager, { settings in
                    var settings = settings
                    settings.callsNativeCapturePath = value
                    return settings
                }).start()
            })
        case let .callsSystemNoiseSuppression(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "System noise suppression", text: "Lets the system voice-processing unit do all noise suppression and drops the extra software one. Default: on. Applies to the next call.", value: value, maximumNumberOfLines: 0, sectionId: self.section, style: .blocks, updated: { value in
                let _ = updateExperimentalUISettingsInteractively(accountManager: arguments.sharedContext.accountManager, { settings in
                    var settings = settings
                    settings.callsSystemNoiseSuppression = value
                    return settings
                }).start()
            })
        case let .callsAdvancedDucking(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Advanced ducking (iOS 17)", text: "Other audio is lowered only while someone speaks, and only a little. Default: off. Applies to the next call.", value: value, maximumNumberOfLines: 0, sectionId: self.section, style: .blocks, updated: { value in
                let _ = updateExperimentalUISettingsInteractively(accountManager: arguments.sharedContext.accountManager, { settings in
                    var settings = settings
                    settings.callsAdvancedDucking = value
                    return settings
                }).start()
            })
        case let .callsGroupNoiseMode(value):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: "Group noise suppression", label: debugGroupNoiseModeTitle(value), sectionId: self.section, style: .blocks, action: {
                let presentationData = arguments.sharedContext.currentPresentationData.with { $0 }
                let actionSheet = ActionSheetController(presentationData: presentationData)
                var items: [ActionSheetItem] = [
                    ActionSheetTextItem(title: "Which noise suppressors run in group calls. Default: RNNoise only. Applies to the next group call.")
                ]
                for mode in [Int32(0), Int32(1), Int32(2)] {
                    items.append(ActionSheetButtonItem(title: debugGroupNoiseModeTitle(mode), color: .accent, action: { [weak actionSheet] in
                        actionSheet?.dismissAnimated()
                        let _ = updateExperimentalUISettingsInteractively(accountManager: arguments.sharedContext.accountManager, { settings in
                            var settings = settings
                            settings.callsGroupNoiseMode = mode
                            return settings
                        }).start()
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
                arguments.presentController(actionSheet, nil)
            })
        case let .callsThermalVideoLadder(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Thermal video limits", text: "When the phone is hot, the outgoing camera video gets smaller and slower. Default: on. Applies at once.", value: value, maximumNumberOfLines: 0, sectionId: self.section, style: .blocks, updated: { value in
                let _ = updateExperimentalUISettingsInteractively(accountManager: arguments.sharedContext.accountManager, { settings in
                    var settings = settings
                    settings.callsThermalVideoLadder = value
                    return settings
                }).start()
            })
        case let .enableNetworkFramework(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Network X [Restart App]", value: value, sectionId: self.section, style: .blocks, updated: { value in
                if let context = arguments.context {
                    let _ = updateNetworkSettingsInteractively(postbox: context.account.postbox, network: context.account.network, { settings in
                        var settings = settings
                        settings.useNetworkFramework = value
                        return settings
                    }).start()
                }
            })
        case let .enableNetworkExperiments(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Download X [Restart App]", value: value, sectionId: self.section, style: .blocks, updated: { value in
                if let context = arguments.context {
                    let _ = updateNetworkSettingsInteractively(postbox: context.account.postbox, network: context.account.network, { settings in
                        var settings = settings
                        settings.useExperimentalDownload = value
                        return settings
                    }).start()
                }
            })
        case let .rustMTProtoEngine(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Rust MTProto [Restart App]", value: value, sectionId: self.section, style: .blocks, updated: { value in
                let _ = updateNetworkEngineSettings(accountManager: arguments.sharedContext.accountManager, { settings in
                    var settings = settings
                    settings.engine = value ? .rust : .mtProtoKit
                    return settings
                }).start()
            })
        case let .networkEngineInfo(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case .performanceExperimentsHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "PERFORMANCE EXPERIMENTS", sectionId: self.section)
        case let .performanceExperiment(experiment, value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: experiment.title, text: performanceExperimentDescription(experiment), value: value, maximumNumberOfLines: 0, sectionId: self.section, style: .blocks, updated: { value in
                UserDefaults.standard.set(value, forKey: experiment.defaultsKey)
                Logger.shared.log("PerfExperiments", "\(experiment.rawValue)=\(value ? "on" : "off") (applies after relaunch)")
                let presentationData = arguments.sharedContext.currentPresentationData.with { $0 }
                arguments.presentController(OverlayStatusController(theme: presentationData.theme, type: .genericSuccess("Force-quit and reopen Nanogram to apply.", false)), nil)
            })
        case let .performanceExperimentsInfo(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case .versionInfo:
            let bundle = Bundle.main
            let bundleId = bundle.bundleIdentifier ?? ""
            let bundleVersion = bundle.infoDictionary?["CFBundleShortVersionString"] ?? ""
            let bundleBuild = bundle.infoDictionary?[kCFBundleVersionKey as String] ?? ""
            return ItemListTextItem(presentationData: presentationData, text: .plain("Nanogram for iOS \(bundleVersion) (\(bundleBuild))\n\(bundleId)"), sectionId: self.section, textAlignment: .center)
        case .collectCpuProfile:
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: "Collect CPU Profile (10s)", kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                let presentationData = arguments.sharedContext.currentPresentationData.with { $0 }
                // A toast, not a blocking overlay: the point is to profile what you do in the app during the
                // next 10 s (scrolling a chat, opening a screen), which the old loading overlay prevented.
                arguments.presentController(OverlayStatusController(theme: presentationData.theme, type: .genericSuccess("Profiling for 10 s. Use the app now.", false)), nil)

                let basePath = arguments.sharedContext.basePath
                CpuProfiler.collectProfile(withDuration: 10.0, sampleRate: 100.0, completion: { report in
                    guard let report = report else {
                        arguments.presentController(OverlayStatusController(theme: presentationData.theme, type: .genericSuccess("A profile is already running", false)), nil)
                        return
                    }

                    let logsPath = basePath + "/logs/profile-logs"
                    let _ = try? FileManager.default.createDirectory(atPath: logsPath, withIntermediateDirectories: true, attributes: nil)

                    let dateFormatter = DateFormatter()
                    dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
                    // The "log-" prefix is what Send Profile Logs (Logger.collectLogs over logs/profile-logs)
                    // picks up; Send Logs reads logs/app-logs and does not include profiles.
                    let fileName = "log-cpu-profile-\(dateFormatter.string(from: Date())).txt"

                    do {
                        try report.write(toFile: logsPath + "/" + fileName, atomically: true, encoding: .utf8)
                        arguments.presentController(OverlayStatusController(theme: presentationData.theme, type: .genericSuccess("Saved \(fileName). Send it with Send Profile Logs.", false)), nil)
                    } catch let error {
                        arguments.presentController(OverlayStatusController(theme: presentationData.theme, type: .genericSuccess("Could not save the profile: \(error.localizedDescription)", false)), nil)
                    }
                })
            })
        case .sendProfileLogs:
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: "Send Profile Logs", label: "", sectionId: self.section, style: .blocks, action: {
                let logsPath = arguments.sharedContext.basePath + "/logs/profile-logs"
                presentDebugLogExport(host: arguments.exportHost, kind: .profileLogs, prepare: debugLogConcatenatedArchiveSignal(Logger(rootPath: logsPath, basePath: logsPath).collectLogs()))
            })
        case .sendMetricKitReports:
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: "Send MetricKit Reports", label: "", sectionId: self.section, style: .blocks, action: {
                // Metric and diagnostic reports MetricKit delivered to this device (MetricReportStore). They
                // leave the device only from here, to a chat, an email or an app you pick.
                var reports = MetricReportStore.shared.reports().map { ($0.name, $0.path) }
                // Who wrote how much, per day (DiskWriteAccounting), to set beside the reports' disk writes.
                if let reporter = DiskWriteAccountingReporting.current, let ledgerPath = DiskWriteAccountingReporting.ledgerPath {
                    reporter.report(reason: "export")
                    if FileManager.default.fileExists(atPath: ledgerPath) {
                        reports.append(("disk-writes.json", ledgerPath))
                    }
                }
                if reports.isEmpty {
                    let presentationData = arguments.sharedContext.currentPresentationData.with { $0 }
                    arguments.presentController(OverlayStatusController(theme: presentationData.theme, type: .genericSuccess("No MetricKit reports yet. iOS delivers them about once a day.", false)), nil)
                    return
                }
                // The JSON reports go into the archive unchanged, so each one still opens as JSON.
                presentDebugLogExport(host: arguments.exportHost, kind: .metricKitReports, prepare: debugLogFilesArchiveSignal(.single(reports)))
            })
        }
    }
}

/// What the Debug Settings entries depend on besides the stored settings, so the list can be built in tests.
struct DebugControllerEntriesEnvironment {
    var isMainApp: Bool
    var hasAccount: Bool
    /// The app configuration marks a Telegram dev account (`dev == 1`).
    var isDevAccount: Bool
    /// `ios_killswitch_disable_neo_round_camera_v2` is set.
    var modernVideoMessagePipelineKilled: Bool
    var networkEngineKind: String?
    var useBetaFeatures: Bool
    /// This device's switches for message widgets (`MessageWidgetLocalSettings`): widgets on by default, the wallet off.
    var messageWidgetsEnabled: Bool = false
    var messageWidgetWalletEnabled: Bool = false
    /// The hardware identifier (`iPhone15,2`) and the stored state of the dark performance experiments.
    var deviceModelIdentifier: String = ""
    var enabledPerformanceExperiments: Set<PerformanceExperiment> = []
    var performanceExperimentSummary: [String] = []
}

func performanceExperimentDescription(_ experiment: PerformanceExperiment) -> String {
    switch experiment {
    case .threadPoolQualityOfService:
        return "Background work (stickers, photo picker) runs on the system's quality-of-service classes instead of fixed priorities. Default: off. Applies after a relaunch."
    case .softwareDecodeThreads:
        return "AV1 videos of 720p or more decode on up to 4 threads (one in Low Power Mode or when the phone is hot). Default: off. Applies after a relaunch."
    case .previewHardwareDecode:
        return "Scrubbing a large H.264 or HEVC video in the gallery decodes previews in hardware. Default: off. Applies after a relaunch."
    }
}

/// The marketing name and chip for the iPhones the A15/A16 experiments are tested on; any other device shows its identifier.
func performanceExperimentsDeviceChip(identifier: String) -> String {
    let known: [String: String] = [
        "iPhone14,4": "iPhone 13 mini (A15)",
        "iPhone14,5": "iPhone 13 (A15)",
        "iPhone14,2": "iPhone 13 Pro (A15)",
        "iPhone14,3": "iPhone 13 Pro Max (A15)",
        "iPhone14,7": "iPhone 14 (A15)",
        "iPhone14,8": "iPhone 14 Plus (A15)",
        "iPhone15,2": "iPhone 14 Pro (A16)",
        "iPhone15,3": "iPhone 14 Pro Max (A16)",
        "iPhone15,4": "iPhone 15 (A16)",
        "iPhone15,5": "iPhone 15 Plus (A16)"
    ]
    if let name = known[identifier] {
        return "\(name), \(identifier)"
    }
    return identifier.isEmpty ? "unknown device" : identifier
}

func debugDeviceModelIdentifier() -> String {
    var size = 0
    guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 else {
        return ""
    }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname("hw.machine", &buffer, &size, nil, 0) == 0 else {
        return ""
    }
    return String(cString: buffer)
}

func debugControllerEntries(environment: DebugControllerEntriesEnvironment, theme: PresentationTheme, loggingSettings: LoggingSettings, experimentalSettings: ExperimentalUISettings, networkSettings: NetworkSettings?, networkEngineSettings: NetworkEngineSettings) -> [DebugControllerEntry] {
    var entries: [DebugControllerEntry] = [.versionInfo(theme)]

    let isMainApp = environment.isMainApp
    
    entries.append(.logsHeader(theme))
    entries.append(.sendReport)
    entries.append(.sendLogs(theme))
    if isMainApp {
        entries.append(.crashReports)
        entries.append(.sendMetricKitReports)
    }
    entries.append(.sendProfileLogs)
    entries.append(.collectCpuProfile)

    entries.append(.logToFile(theme, loggingSettings.logToFile))
    entries.append(.logToConsole(theme, loggingSettings.logToConsole))
    entries.append(.redactSensitiveData(theme, loggingSettings.redactSensitiveData))
    entries.append(.logNetworkDumps(theme, loggingSettings.logNetworkDumps))
    entries.append(.logsInfo(theme))

    entries.append(.resetAppHeader(theme))
    entries.append(.resetDatabase(theme))
    entries.append(.resetDatabaseAndCache(theme))
    if isMainApp {
        entries.append(.resetNotifications)
        entries.append(.reindexUnread(theme))
        entries.append(.reindexCache)
    }
    entries.append(.optimizeDatabase(theme))

    entries.append(.experimentsHeader(theme))
    if isMainApp {
        entries.append(.keepChatNavigationStack(theme, experimentalSettings.keepChatNavigationStack))
        #if DEBUG
        entries.append(.skipReadHistory(theme, experimentalSettings.skipReadHistory))
        #endif
        entries.append(.alwaysDisplayTyping(experimentalSettings.alwaysDisplayTyping))
    }
    entries.append(.forceListViewImplChatBackend(experimentalSettings.forceListViewImplChatBackend))
    entries.append(.coreListScrollTrace(experimentalSettings.coreListScrollTrace))
    entries.append(.respectSystemMicrophone(experimentalSettings.respectSystemMicrophone))
    let useModernVideoMessagePipeline = (experimentalSettings.useModernVideoMessagePipeline ?? !environment.modernVideoMessagePipelineKilled) && experimentalSettings.videoMessageCameraMode != .legacy
    entries.append(.videoMessageCameraMode(useModernVideoMessagePipeline ? experimentalSettings.videoMessageCameraMode : .legacy))
    entries.append(.videoMessageCloseFocus(experimentalSettings.videoMessageCloseFocus))
    entries.append(.videoMessageCameraMatrix(experimentalSettings.videoMessageCameraMatrix))
    entries.append(.crashOnSlowQueries(theme, experimentalSettings.crashOnLongQueries))
    entries.append(.crashOnMemoryPressure(theme, experimentalSettings.crashOnMemoryPressure))
    if isMainApp {
        entries.append(.fakeGlass(experimentalSettings.fakeGlass))
        entries.append(.inputDecEngineEditor(experimentalSettings.useInputDecEngine))
        entries.append(.checkSerializedData(experimentalSettings.checkSerializedData))
        entries.append(.enableQuickReactionSwitch(!experimentalSettings.disableQuickReaction))
        entries.append(.liveStreamV2(experimentalSettings.liveStreamV2))
        entries.append(.groupCallReferenceEngine(experimentalSettings.groupCallReferenceEngine))
        entries.append(.springSendAnimation(experimentalSettings.springSendAnimation))
        if environment.isDevAccount {
            entries.append(.fakeWalletTransfers(experimentalSettings.fakeWalletTransfers))
        }
        entries.append(.stickerRendererMode(experimentalSettings.stickerRendererMode))
        entries.append(.compressedEmojiCache(experimentalSettings.compressedEmojiCache))
        entries.append(.disableImageContentAnalysis(experimentalSettings.disableImageContentAnalysis))
        entries.append(.disableLanguageRecognition(experimentalSettings.disableLanguageRecognition))
        entries.append(.enableVoipTcp(experimentalSettings.enableVoipTcp))
        entries.append(.chatMediaEditorLegacy(experimentalSettings.chatMediaEditorLegacy))
        entries.append(.mediaGridLegacy(experimentalSettings.mediaGridLegacy))
        entries.append(.sharedMediaGridLegacy(experimentalSettings.sharedMediaGridLegacy))
        entries.append(.storyLegacyVideoWriter(experimentalSettings.storyLegacyVideoWriter))
        entries.append(.chatLegacyVideoWriter(experimentalSettings.chatLegacyVideoWriter))
        entries.append(.chatSideListLegacy(experimentalSettings.chatSideListLegacy))
        entries.append(.messageWidgets(environment.messageWidgetsEnabled))
        entries.append(.messageWidgetWallet(environment.messageWidgetWalletEnabled))
        entries.append(.stickerParallelQueues(experimentalSettings.stickerParallelQueues))
        entries.append(.gifGridParallelDecode(experimentalSettings.gifGridParallelDecode))
    }

    if isMainApp {
        // The user-facing call switches (noise suppression, ducking, thermal limits) and the glanceables switch moved to Settings > Nanogram Features.
        entries.append(.callsHeader(theme))
        entries.append(.callsLivestreamHardwareDecoding(experimentalSettings.callsLivestreamHardwareDecoding))
        entries.append(.callsNativeCapturePath(experimentalSettings.callsNativeCapturePath))
        
        // Measurement only: each switch replaces one chat glass group with a solid fill (iOS native glass).
        entries.append(.glassGroupsHeader(theme))
        entries.append(.glassGroupNavigationBar(experimentalSettings.glassDebugDisabledGroups & ExperimentalUISettings.glassDebugNavigationBar != 0))
        entries.append(.glassGroupInputPanel(experimentalSettings.glassDebugDisabledGroups & ExperimentalUISettings.glassDebugInputPanel != 0))
        entries.append(.glassGroupFloatingButtons(experimentalSettings.glassDebugDisabledGroups & ExperimentalUISettings.glassDebugFloatingButtons != 0))
        
        // Performance: the frame-hitch log and the back-swipe preparation (the other performance switches are always on now).
        entries.append(.performanceHeader(theme))
        entries.append(.frameHitchLog(experimentalSettings.frameHitchLog))
        entries.append(.backSwipePreparePreviousScreen(experimentalSettings.backSwipePreparePreviousScreen))

        // Dark performance experiments for A/B tests on iPhone 14 and 14 Pro: stored in UserDefaults, read at launch.
        entries.append(.performanceExperimentsHeader(theme))
        for experiment in PerformanceExperiment.allCases {
            entries.append(.performanceExperiment(experiment, environment.enabledPerformanceExperiments.contains(experiment)))
        }
        var infoLines = ["Device: \(performanceExperimentsDeviceChip(identifier: environment.deviceModelIdentifier))", "Force-quit and reopen Nanogram after changing a switch. Send Report includes these numbers (durations only, no content)."]
        infoLines.append(contentsOf: environment.performanceExperimentSummary)
        entries.append(.performanceExperimentsInfo(infoLines.joined(separator: "\n")))
    }

    if isMainApp {
        entries.append(.resetWebViewCache(theme))

        entries.append(.enableNetworkFramework(networkSettings?.useNetworkFramework ?? environment.useBetaFeatures))
        entries.append(.enableNetworkExperiments(networkSettings?.useExperimentalDownload ?? true))
        entries.append(.rustMTProtoEngine(networkEngineSettings.engine == .rust))
        if let networkEngineKind = environment.networkEngineKind {
            // The engine this account actually runs. The switch alone does not say: the factory
            // still declines (WEB proxy, DC address overrides) and mtproto_engine_rust_disabled
            // forces MtProtoKit.
            entries.append(.networkEngineInfo("Engine: \(networkEngineKind)"))
        }
    }
    
    return entries
}

public func debugController(sharedContext: SharedAccountContext, context: AccountContext?, modal: Bool = false) -> ViewController {
    var presentControllerImpl: ((ViewController, ViewControllerPresentationArguments?) -> Void)?
    var pushControllerImpl: ((ViewController) -> Void)?
    var dismissImpl: (() -> Void)?
    var getRootControllerImpl: (() -> UIViewController?)?
    var getNavigationControllerImpl: (() -> NavigationController?)?
    
    let arguments = DebugControllerArguments(sharedContext: sharedContext, context: context, presentController: { controller, arguments in
        presentControllerImpl?(controller, arguments)
    }, pushController: { controller in
        pushControllerImpl?(controller)
    }, getRootController: {
        return getRootControllerImpl?()
    }, getNavigationController: {
        return getNavigationControllerImpl?()
    })
    
    let preferencesSignal: Signal<EnginePreferencesEntry?, NoError>
    if let context = context {
        preferencesSignal = context.engine.data.subscribe(TelegramEngine.EngineData.Item.Configuration.ApplicationSpecificPreference(key: PreferencesKeys.networkSettings))
    } else {
        preferencesSignal = .single(nil)
    }
    
    let signal = combineLatest(sharedContext.presentationData, sharedContext.accountManager.sharedData(keys: Set([SharedDataKeys.loggingSettings, ApplicationSpecificSharedDataKeys.experimentalUISettings, SharedDataKeys.networkEngineSettings])), preferencesSignal)
    |> map { presentationData, sharedData, preferences -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let loggingSettings: LoggingSettings
        if let value = sharedData.entries[SharedDataKeys.loggingSettings]?.get(LoggingSettings.self) {
            loggingSettings = value
        } else {
            loggingSettings = LoggingSettings.defaultSettings
        }
        
        let experimentalSettings: ExperimentalUISettings = sharedData.entries[ApplicationSpecificSharedDataKeys.experimentalUISettings]?.get(ExperimentalUISettings.self) ?? ExperimentalUISettings.defaultSettings
        
        let networkSettings: NetworkSettings? = preferences?.get(NetworkSettings.self)
        let networkEngineSettings: NetworkEngineSettings = sharedData.entries[SharedDataKeys.networkEngineSettings]?.get(NetworkEngineSettings.self) ?? NetworkEngineSettings.defaultSettings
        
        var leftNavigationButton: ItemListNavigationButton?
        if modal {
            leftNavigationButton = ItemListNavigationButton(content: .icon(.close), style: .regular, enabled: true, action: {
                dismissImpl?()
            })
        }
        
        var useBetaFeatures: Bool = false
        if let context {
            useBetaFeatures = context.account.network.useBetaFeatures
        }
        
        var isDevAccount = false
        if let data = context?.currentAppConfiguration.with({ $0 }).data, let isDev = data["dev"] as? Double, isDev == 1.0 {
            isDevAccount = true
        }
        let environment = DebugControllerEntriesEnvironment(
            isMainApp: sharedContext.applicationBindings.isMainApp,
            hasAccount: context != nil,
            isDevAccount: isDevAccount,
            modernVideoMessagePipelineKilled: context?.getAppConfigValue("ios_killswitch_disable_neo_round_camera_v2") != nil,
            networkEngineKind: context?.account.network.engineKind.rawValue,
            useBetaFeatures: useBetaFeatures,
            messageWidgetsEnabled: MessageWidgetLocalSettings.widgetsEnabled(),
            messageWidgetWalletEnabled: MessageWidgetLocalSettings.walletEnabled(),
            deviceModelIdentifier: debugDeviceModelIdentifier(),
            enabledPerformanceExperiments: Set(PerformanceExperiment.allCases.filter { ExperimentalPerformanceFlags.shared.isEnabled($0) }),
            performanceExperimentSummary: PerformanceExperimentStats.shared.summaryLines() + DebugEnergy.summaryLines()
        )
        
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text("Debug Settings"), leftNavigationButton: leftNavigationButton, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: debugControllerEntries(environment: environment, theme: presentationData.theme, loggingSettings: loggingSettings, experimentalSettings: experimentalSettings, networkSettings: networkSettings, networkEngineSettings: networkEngineSettings), style: .blocks)
        
        return (controllerState, (listState, arguments))
    }
    
    
    let controller = ItemListController(sharedContext: sharedContext, state: signal)
    arguments.openLogs = { [weak controller, weak arguments] in
        guard let controller, let arguments,
              let sourceNode = controller.itemNode(forTag: DebugControllerItemTag.sendLogs) as? ItemListActionItemNode else {
            return
        }
        var options: [DebugLogAction] = [.sendLogs, .sendShareLogs]
        if arguments.context != nil {
            options.append(.sendGroupCallLogs)
            options.append(.sendCallLogs)
        }
        options.append(contentsOf: [.sendNotificationLogs, .sendCriticalLogs, .sendAllLogs])
        if sharedContext.applicationBindings.isMainApp {
            options.append(.sendStorageStats)
        }
        // Picking a kind asks where to send it: a chat, an email or another app, the same for every kind.
        let items: [ContextMenuItem] = options.map { option in
            return .action(ContextMenuActionItem(text: option.title, textLayout: option.textLayout, icon: { _ in nil }, action: { menu, _ in
                menu?.dismiss(completion: {
                    option.present(arguments: arguments)
                })
            }))
        }
        let menu = makeContextController(
            presentationData: sharedContext.currentPresentationData.with { $0 },
            source: .reference(DebugLogsContextReferenceContentSource(sourceView: sourceNode.view)),
            items: .single(ContextController.Items(content: .list(items))),
            gesture: nil
        )
        controller.presentInGlobalOverlay(menu, with: nil)
    }
    presentControllerImpl = { [weak controller] c, a in
        controller?.present(c, in: .window(.root), with: a)
    }
    pushControllerImpl = { [weak controller] c in
        (controller?.navigationController as? NavigationController)?.pushViewController(c)
    }
    dismissImpl = { [weak controller] in
        controller?.dismiss()
    }
    getRootControllerImpl = { [weak controller] in
        return controller?.view.window?.rootViewController
    }
    getNavigationControllerImpl = { [weak controller] in
        return controller?.navigationController as? NavigationController
    }
    return controller
}

/// The chat message menu's "Send Logs": the app logs plus `additionalInfo`, to a chat, an email or another app.
public func triggerDebugSendLogsUI(context: AccountContext, additionalInfo: String = "", pushController: @escaping (ViewController) -> Void) {
    let host = DebugLogExportHost(sharedContext: context.sharedContext, context: context, present: { [weak context] controller in
        context?.sharedContext.mainWindow?.present(controller, on: .root)
    }, push: pushController, rootViewController: { [weak context] in
        return context?.sharedContext.mainWindow?.hostView.containerView.window?.rootViewController
    })
    presentDebugLogExport(host: host, kind: .mediaDownloadLogs, prepare: debugLogConcatenatedArchiveSignal(Logger.shared.collectLogs(), additionalInfo: additionalInfo))
}
