import UIKit
import SwiftSignalKit
import Display
import TelegramCore
import UserNotifications
import Intents
import Postbox
import PushKit
import AsyncDisplayKit
import TelegramUIPreferences
import NotificationsPresentationData
import TelegramPresentationData
import TelegramCallsUI
import TelegramVoip
import BuildConfig
import BuildConfigExtra
import DeviceCheck
import AccountContext
import OverlayStatusController
import UndoUI
import LegacyUI
import PassportUI
import SettingsUI
import AppBundle
import UrlHandling
import OpenSSLEncryptionProvider
import AppLock
import PresentationDataUtils
import TelegramIntents
import AccountUtils
import CoreSpotlight
import TelegramAudio
import DebugSettingsUI
import CrashReporting
import BackgroundTasks
import UIKitRuntimeUtils
import StoreKit
import PhoneNumberFormat
import AuthorizationUI
import ManagedFile
import ShareItems
import DeviceProximity
import MediaEditor
import TelegramUIDeclareEncodables
import ContextMenuScreen
import MetalEngine
import RecaptchaEnterprise
import NavigationBarNode
import NavigationBarComponent
import NavigationExpansionTransition
import ContextUI
import ContextControllerImpl
import ProxyServerPreviewScreen
import WalletContext
import WalletSendScreen
import PasscodeCore
import LiquidGlassShapes
import AnimatedStickerNode
import MTProtoRustEngine
import BackgroundDiagnostics
import DiskWriteAccounting

#if DEBUG
import AlertComponent
#endif

#if canImport(AppCenter)
import AppCenter
import AppCenterCrashes
#endif

private let handleVoipNotifications = false

private func isTonTransferUrl(_ url: URL) -> Bool {
    return url.scheme?.lowercased() == "ton" && url.host?.lowercased() == "transfer"
        && WalletContext.transferAddress(from: url.absoluteString) != nil
}

private var testIsLaunched = false

private func isKeyboardWindow(window: NSObject) -> Bool {
    let typeName = NSStringFromClass(type(of: window))
    if #available(iOS 9.0, *) {
        if typeName.hasPrefix("UI") && typeName.hasSuffix("RemoteKeyboardWindow") {
            return true
        }
    } else {
        if typeName.hasPrefix("UI") && typeName.hasSuffix("TextEffectsWindow") {
            return true
        }
    }
    return false
}

private func isKeyboardView(view: NSObject) -> Bool {
    let typeName = NSStringFromClass(type(of: view))
    if typeName.hasPrefix("UI") && typeName.hasSuffix("InputSetHostView") {
        return true
    }
    if typeName.hasPrefix("UI") && typeName.hasSuffix("KeyboardItemContainerView") {
        return true
    }
    return false
}

private func isKeyboardViewContainer(view: NSObject) -> Bool {
    let typeName = NSStringFromClass(type(of: view))
    if typeName.hasPrefix("UI") && typeName.hasSuffix("InputSetContainerView") {
        return true
    }
    if typeName.hasPrefix("UI") && typeName.hasSuffix("TrackingWindowView") {
        return true
    }
    return false
}

private class ApplicationStatusBarHost: StatusBarHost {
    weak var scene: UIWindowScene?
    
    init(scene: UIWindowScene?) {
        self.scene = scene
    }
    
    var isApplicationInForeground: Bool {
        guard let scene = self.scene else {
            return false
        }
        switch scene.activationState {
        case .unattached:
            return false
        case .foregroundActive:
            return true
        case .foregroundInactive:
            return true
        case .background:
            return false
        @unknown default:
            return false
        }
    }
    
    var statusBarFrame: CGRect {
        guard let scene = self.scene else {
            return CGRect()
        }
        return scene.statusBarManager?.statusBarFrame ?? CGRect()
    }
    
    var keyboardWindow: UIWindow? {
        // The keyboard window belongs to an internal keyboard scene, so it is not enumerable through
        // any public API; it is reached through our own window scene's keyboard scene delegate.
        if let window = UIApplication.shared.internalGetKeyboard(for: self.scene) {
            return window
        }

        // Pre-iOS-16 the keyboard window was not flagged as internal and did show up in the scene's
        // window list, so this remains as a fallback for those releases.
        for window in UIApplication.shared.allWindowSceneWindows {
            if isKeyboardWindow(window: window) {
                return window
            }
        }
        return nil
    }
    
    var keyboardView: UIView? {
        guard let keyboardWindow = self.keyboardWindow else {
            return nil
        }
        
        for view in keyboardWindow.subviews {
            if isKeyboardViewContainer(view: view) {
                for subview in view.subviews {
                    if isKeyboardView(view: subview) {
                        return subview
                    }
                }
            }
        }
        return nil
    }
}

private func legacyDocumentsPath() -> String {
    return NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0] + "/legacy"
}

private enum QueuedWakeup: Int32 {
    case call
    case backgroundLocation
}

final class SharedApplicationContext {
    let sharedContext: SharedAccountContextImpl
    let notificationManager: SharedNotificationManager
    let wakeupManager: SharedWakeupManager
    let overlayMediaController: ViewController & OverlayMediaController
    var minimizedContainer: [AccountRecordId: MinimizedContainer] = [:]
    
    init(sharedContext: SharedAccountContextImpl, notificationManager: SharedNotificationManager, wakeupManager: SharedWakeupManager) {
        self.sharedContext = sharedContext
        self.notificationManager = notificationManager
        self.wakeupManager = wakeupManager
        self.overlayMediaController = OverlayMediaControllerImpl()
    }
}

private struct AccountManagerState {
    struct NotificationKey {
        var accountId: AccountRecordId
        var id: Data
        var key: Data
    }

    var notificationKeys: [NotificationKey]
}

private func extractAccountManagerState(records: AccountRecordsView<TelegramAccountManagerTypes>) -> AccountManagerState {
    return AccountManagerState(
        notificationKeys: records.records.compactMap { record -> AccountManagerState.NotificationKey? in
            for attribute in record.attributes {
                if case let .backupData(backupData) = attribute {
                    if let notificationEncryptionKeyId = backupData.data?.notificationEncryptionKeyId, let notificationEncryptionKey = backupData.data?.notificationEncryptionKey {
                        return AccountManagerState.NotificationKey(
                            accountId: record.id,
                            id: notificationEncryptionKeyId,
                            key: notificationEncryptionKey
                        )
                    }
                }
            }
            return nil
        }
    )
}

@objc(AppDelegate) class AppDelegate: UIResponder, UIApplicationDelegate, PKPushRegistryDelegate, UNUserNotificationCenterDelegate, URLSessionDelegate, URLSessionTaskDelegate {
    @objc var window: UIWindow?
    var nativeWindow: (UIWindow & WindowHost)?
    var mainWindow: Window1!
    private var statusBarHost: ApplicationStatusBarHost?
    private var dataImportSplash: LegacyDataImportSplash?
    private var memoryUsageOverlayView: UILabel?
    
    private let crashReportPromptDisposable = MetaDisposable()
    private var buildConfig: BuildConfig?
    let episodeId = arc4random()
    
    private let isInForegroundPromise = ValuePromise<Bool>(false, ignoreRepeated: true)
    private var isInForegroundValue = false
    private let isActivePromise = ValuePromise<Bool>(false, ignoreRepeated: true)
    private var isActiveValue = false
    /// `isActive` / `isInForeground` as thread-safe flags: the VACUUM gate in the cleanup task asks on the Postbox
    /// queue, where UIApplication.applicationState must not be read.
    private let maintenanceIsActive = Atomic<Bool>(value: false)
    private let maintenanceIsInForeground = Atomic<Bool>(value: false)
    let hasActiveAudioSession = Promise<Bool>(false)
    
    private let sharedContextPromise = Promise<SharedApplicationContext>()
    /// The "lock" background task begun on the latest entry into the background.
    private var lockBackgroundTask: OneShotBackgroundTask<UIBackgroundTaskIdentifier>?
    private var diskWriteReportTimer: Foundation.Timer?
    
    private lazy var backgroundDiagnostics = BackgroundDiagnosticsScheduler(now: {
        // Wall clock, so a suspension in between shows as a late report.
        return CFAbsoluteTimeGetCurrent()
    }, schedule: { delay, block in
        DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + delay, execute: {
            MainActor.assumeIsolated {
                block()
            }
        })
    })

    private var accountManager: AccountManager<TelegramAccountManagerTypes>?
    private var accountManagerState: AccountManagerState?
    
    private var contextValue: AuthorizedApplicationContext?
    private let context = Promise<AuthorizedApplicationContext?>()
    private let contextDisposable = MetaDisposable()
    
    private var authContextValue: UnauthorizedApplicationContext?
    private let authContext = Promise<UnauthorizedApplicationContext?>()
    private let authContextDisposable = MetaDisposable()
    
    private let logoutDisposable = MetaDisposable()
    
    private let openNotificationSettingsWhenReadyDisposable = MetaDisposable()
    private let openChatWhenReadyDisposable = MetaDisposable()
    private let openUrlWhenReadyDisposable = MetaDisposable()
    
    private let badgeDisposable = MetaDisposable()
    private let quickActionsDisposable = MetaDisposable()
    
    private var pushRegistry: PKPushRegistry?
    
    private let notificationAuthorizationDisposable = MetaDisposable()
    
    private var replyFromNotificationsDisposables = DisposableSet()
    private var watchedCallsDisposables = DisposableSet()
    
    private var _notificationTokenPromise: Promise<Data>?
    private let voipTokenPromise = Promise<Data>()
    
    private var firebaseSecrets: [String: String] = [:] {
        didSet {
            if self.firebaseSecrets != oldValue {
                self.firebaseSecretStream.set(.single(self.firebaseSecrets))
            }
        }
    }
    private let firebaseSecretStream = Promise<[String: String]>([:])
    
    private var firebaseRequestVerificationSecrets: [String: String] = [:] {
        didSet {
            if self.firebaseRequestVerificationSecrets != oldValue {
                self.firebaseRequestVerificationSecretStream.set(.single(self.firebaseRequestVerificationSecrets))
            }
        }
    }
    private let firebaseRequestVerificationSecretStream = Promise<[String: String]>([:])
    
    private var urlSessions: [URLSession] = []
    private func urlSession(identifier: String) -> URLSession {
        if let existingSession = self.urlSessions.first(where: { $0.configuration.identifier == identifier }) {
            return existingSession
        }
        
        let baseAppBundleId = Bundle.main.bundleIdentifier!
        let appGroupName = "group.\(baseAppBundleId)"

        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.sharedContainerIdentifier = appGroupName
        configuration.isDiscretionary = false
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        self.urlSessions.append(session)
        return session
    }
    
    private var pendingUrlSessionBackgroundEventsCompletion: (() -> Void)?
    
    private var notificationTokenPromise: Promise<Data> {
        if let current = self._notificationTokenPromise {
            return current
        } else {
            let promise = Promise<Data>()
            self._notificationTokenPromise = promise
            
            return promise
        }
    }
    
    private var clearNotificationsManager: ClearNotificationsManager?
    
    private let idleTimerExtensionSubscribers = Bag<Void>()
    
    private var alertActions: (primary: (() -> Void)?, other: (() -> Void)?)?
    
    private let voipDeviceToken = Promise<Data?>(nil)
    private let regularDeviceToken = Promise<Data?>(nil)
    
    private var recaptchaClientsBySiteKey: [String: Promise<RecaptchaClient>] = [:]
        
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        precondition(!testIsLaunched)
        testIsLaunched = true
        CrashReportCollector.shared.start()
        
        let _ = voipTokenPromise.get().start(next: { token in
            self.voipDeviceToken.set(.single(token))
        })
        let _ = notificationTokenPromise.get().start(next: { token in
            self.regularDeviceToken.set(.single(token))
        })
        
        let launchStartTime = CFAbsoluteTimeGetCurrent()
        
        defaultNavigationBarImpl = { presentationData in
            return NavigationBarNode(presentationData: presentationData)
        }
        defaultNavigationBarTransitionRenderer = { bottom, top in
            return makeNavigationBarTransitionRenderer(bottom: bottom, top: top)
        }
        defaultNavigationExpansionRenderer = { source, destination, operation in
            return NavigationExpansionRendererImpl.make(source: source, destination: destination, operation: operation)
        }
        makeContextControllerImpl = { context, presentationData, configuration, recognizer, gesture, workaroundUseLegacyImplementation, disableScreenshots, hideReactionPanelTail in
            return ContextControllerImpl(
                context: context,
                presentationData: presentationData,
                configuration: configuration,
                recognizer: recognizer,
                gesture: gesture,
                workaroundUseLegacyImplementation: workaroundUseLegacyImplementation,
                disableScreenshots: disableScreenshots,
                hideReactionPanelTail: hideReactionPanelTail
            )
        }
        makeContextControllerActionsStackNodeImpl = { context, getController, requestDismiss, requestUpdate in
            return ContextControllerActionsStackNodeImpl(
                context: context,
                getController: getController,
                requestDismiss: requestDismiss,
                requestUpdate: requestUpdate
            )
        }
        makeContextControllerActionsListStackItemImpl = { id, items, reactionItems, previewReaction, tip, tipSignal, dismissed in
            return ContextControllerActionsListStackItem(
                id: id,
                items: items,
                reactionItems: reactionItems,
                previewReaction: previewReaction,
                tip: tip,
                tipSignal: tipSignal,
                dismissed: dismissed
            )
        }
        makeContextActionNodeImpl = { presentationData, action, getController, actionSelected, requestLayout, requestUpdateAction in
            return ContextActionNode(
                presentationData: presentationData,
                action: action,
                getController: getController,
                actionSelected: actionSelected,
                requestLayout: requestLayout,
                requestUpdateAction: requestUpdateAction
            )
        }
        makePeekControllerImpl = { presentationData, content, sourceView, activateImmediately in
            return PeekControllerImpl(
                presentationData: presentationData,
                content: content,
                sourceView: sourceView,
                activateImmediately: activateImmediately
            )
        }
        makePinchControllerImpl = { sourceNode, disableScreenshots, getContentAreaInScreenSpace in
            return PinchControllerImpl(
                sourceNode: sourceNode,
                disableScreenshots: disableScreenshots,
                getContentAreaInScreenSpace: getContentAreaInScreenSpace
            )
        }
        
        let (window, hostView) = nativeWindowHostView()
        let statusBarHost = ApplicationStatusBarHost(scene: window.windowScene)
        self.statusBarHost = statusBarHost
        self.mainWindow = Window1(hostView: hostView, statusBarHost: statusBarHost)
        if let traitCollection = window.rootViewController?.traitCollection {
            if #available(iOS 13.0, *) {
                switch traitCollection.userInterfaceStyle {
                case .light, .unspecified:
                    hostView.containerView.backgroundColor = UIColor.white
                default:
                    hostView.containerView.backgroundColor = UIColor.black
                }
            } else {
                hostView.containerView.backgroundColor = UIColor.white
            }
        } else {
            hostView.containerView.backgroundColor = UIColor.white
        }
        self.window = window
        self.nativeWindow = window
        
        // iPad (audit A-6): the iPadOS 26 menu bar lists the visible screens' shortcuts (File, View, Chat, Format).
        if #available(iOS 26.0, *), mainMenuIsInstalled(deviceType: self.mainWindow?.deviceType ?? .phone, available: true) {
            MainMenuInstaller.chatMenuTitle = { [weak self] in
                return self?.contextValue?.context.sharedContext.currentPresentationData.with({ $0 }).strings.Chat_BottomSearchPanel_DisplayModeChat ?? "Chat"
            }
            MainMenuInstaller.formatMenuTitle = { [weak self] in
                return self?.contextValue?.context.sharedContext.currentPresentationData.with({ $0 }).strings.TextFormat_Format ?? "Format"
            }
            MainMenuInstaller.install()
        }
        
        hostView.containerView.layer.addSublayer(MetalEngine.shared.rootLayer)
        // Compile the pipelines that would otherwise stall their first use. Not only on a fresh archive: while the
        // archive is switched off `isFresh` is always false and every launch compiles them on first use.
        prewarmLiquidGlassShapes([.crest], qos: .utility)
        // Likewise the sticker renderer's Metal device, shader library and pipelines, which the first
        // large sticker or emoji otherwise sets up on the main thread.
        AnimatedStickerMetalPrewarm.start()
        
        if !UIDevice.current.isBatteryMonitoringEnabled {
            UIDevice.current.isBatteryMonitoringEnabled = true
        }
        
        let clearNotificationsManager = ClearNotificationsManager(getNotificationIds: { [weak self] completion in
            if #available(iOS 10.0, *) {
                UNUserNotificationCenter.current().getDeliveredNotifications(completionHandler: { notifications in
                    self?.removeStaleServicePushNotifications(notifications)

                    var result: [(String, NotificationManagedNotificationRequestId)] = []
                    for notification in notifications {
                        if let requestId = NotificationManagedNotificationRequestId(string: notification.request.identifier) {
                            result.append((notification.request.identifier, requestId))
                        } else {
                            let payload = notification.request.content.userInfo
                            var notificationRequestId: NotificationManagedNotificationRequestId?
                            
                            var peerId: PeerId?
                            if let fromId = payload["from_id"] {
                                let fromIdValue = fromId as! NSString
                                peerId = PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value(Int64(fromIdValue as String) ?? 0))
                            } else if let fromId = payload["chat_id"] {
                                let fromIdValue = fromId as! NSString
                                peerId = PeerId(namespace: Namespaces.Peer.CloudGroup, id: PeerId.Id._internalFromInt64Value(Int64(fromIdValue as String) ?? 0))
                            } else if let fromId = payload["channel_id"] {
                                let fromIdValue = fromId as! NSString
                                peerId = PeerId(namespace: Namespaces.Peer.CloudChannel, id: PeerId.Id._internalFromInt64Value(Int64(fromIdValue as String) ?? 0))
                            }
                            
                            if let msgId = payload["msg_id"] {
                                let msgIdValue = msgId as! NSString
                                if let peerId = peerId {
                                    notificationRequestId = .messageId(MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: Int32(msgIdValue.intValue)))
                                }
                            }
                            
                            if let notificationRequestId = notificationRequestId {
                                result.append((notification.request.identifier, notificationRequestId))
                            }
                        }
                    }
                    completion.f(result)
                })
            } else {
                var result: [(String, NotificationManagedNotificationRequestId)] = []
                if let notifications = UIApplication.shared.scheduledLocalNotifications {
                    for notification in notifications {
                        if let userInfo = notification.userInfo, let id = userInfo["id"] as? String {
                            if let requestId = NotificationManagedNotificationRequestId(string: id) {
                                result.append((id, requestId))
                            }
                        }
                    }
                }
                completion.f(result)
            }
        }, removeNotificationIds: { ids in
            if #available(iOS 10.0, *) {
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
            } else {
                if let notifications = UIApplication.shared.scheduledLocalNotifications {
                    for notification in notifications {
                        if let userInfo = notification.userInfo, let id = userInfo["id"] as? String {
                            if ids.contains(id) {
                                UIApplication.shared.cancelLocalNotification(notification)
                            }
                        }
                    }
                }
            }
        }, getPendingNotificationIds: { completion in
            if #available(iOS 10.0, *) {
                UNUserNotificationCenter.current().getPendingNotificationRequests(completionHandler: { requests in
                    var result: [(String, NotificationManagedNotificationRequestId)] = []
                    for request in requests {
                        if let requestId = NotificationManagedNotificationRequestId(string: request.identifier) {
                            result.append((request.identifier, requestId))
                        }
                    }
                    completion.f(result)
                })
            } else {
                var result: [(String, NotificationManagedNotificationRequestId)] = []
                if let notifications = UIApplication.shared.scheduledLocalNotifications {
                    for notification in notifications {
                        if let userInfo = notification.userInfo, let id = userInfo["id"] as? String {
                            if let requestId = NotificationManagedNotificationRequestId(string: id) {
                                result.append((id, requestId))
                            }
                        }
                    }
                }
                completion.f(result)
            }
        }, removePendingNotificationIds: { ids in
            if #available(iOS 10.0, *) {
                UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
            } else {
                if let notifications = UIApplication.shared.scheduledLocalNotifications {
                    for notification in notifications {
                        if let userInfo = notification.userInfo, let id = userInfo["id"] as? String {
                            if ids.contains(id) {
                                UIApplication.shared.cancelLocalNotification(notification)
                            }
                        }
                    }
                }
            }
        })
        self.clearNotificationsManager = clearNotificationsManager
        
        let appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown"
        
        let baseAppBundleId = Bundle.main.bundleIdentifier!
        let appGroupName = "group.\(baseAppBundleId)"
        try! PasscodeEnvironment.shared.configure(PasscodeConfiguration(appGroupIdentifier: appGroupName, processRole: .mainApp, biometricKeychainService: walletBiometricKeychainService), privateAccessGroup: {
            BuildConfig.keychainAccessGroup(baseAppBundleId: baseAppBundleId)
        })
        let maybeAppGroupUrl = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupName)
        
        let buildConfig = BuildConfig(baseAppBundleId: baseAppBundleId)
        self.buildConfig = buildConfig
        let signatureDict = BuildConfigExtra.signatureDict()
        
        let apiId: Int32 = buildConfig.apiId
        let apiHash: String = buildConfig.apiHash
        let languagesCategory = "ios"
        
        let autolockDeadine: Signal<Int32?, NoError>
        if #available(iOS 10.0, *) {
            autolockDeadine = .single(nil)
        } else {
            autolockDeadine = self.context.get()
            |> mapToSignal { context -> Signal<Int32?, NoError> in
                guard let context = context else {
                    return .single(nil)
                }
                return context.context.sharedContext.appLockContext.autolockDeadline
            }
        }
        
        let networkArguments = NetworkInitializationArguments(
            apiId: apiId,
            apiHash: apiHash,
            languagesCategory: languagesCategory,
            appVersion: appVersion,
            voipMaxLayer: PresentationCallManagerImpl.voipMaxLayer,
            voipVersions: PresentationCallManagerImpl.voipVersions(includeExperimental: true, includeReference: false).map { version, supportsVideo -> CallSessionManagerImplementationVersion in
                CallSessionManagerImplementationVersion(version: version, supportsVideo: supportsVideo)
            },
            appData: self.regularDeviceToken.get() |> map { token in
                let tokenEnvironment: String
                #if DEBUG
                tokenEnvironment = "sandbox"
                #else
                tokenEnvironment = "production"
                #endif
                
                let data = buildConfig.bundleData(withAppToken: token, tokenType: "apns", tokenEnvironment: tokenEnvironment, signatureDict: signatureDict)
                if let data = data, let _ = String(data: data, encoding: .utf8) {
                } else {
                    Logger.shared.log("data", "can't deserialize")
                }
                return data
            },
            externalRequestVerificationStream: self.firebaseRequestVerificationSecretStream.get(),
            externalRecaptchaRequestVerification: { method, siteKey in
                return Signal<String?, NoError> { subscriber in
                    // Recaptcha.fetchClient's completion is @Sendable, so it does not inherit this
                    // closure's inferred main-actor isolation: from inside it neither the Promise (a
                    // lock-based pre-concurrency class, so not Sendable) nor self's mutable state may
                    // be touched. Both spellings are diagnosed, and Xcode 26's compiler raises them to
                    // errors under -warnings-as-errors (Xcode 27's leaves them as warnings). The
                    // promise is in fact only ever set on the main queue, which Queue.mainQueue()
                    // guarantees and the compiler cannot see - hence the explicit opt-out.
                    nonisolated(unsafe) let recaptchaClient: Promise<RecaptchaClient>
                    if let current = self.recaptchaClientsBySiteKey[siteKey] {
                        recaptchaClient = current
                    } else {
                        recaptchaClient = Promise<RecaptchaClient>()
                        self.recaptchaClientsBySiteKey[siteKey] = recaptchaClient
                        
                        Recaptcha.fetchClient(withSiteKey: siteKey) { client, error in
                            Queue.mainQueue().async {
                                guard let client else {
                                    Logger.shared.log("App \(self.episodeId)", "RecaptchaClient creation error: \(String(describing: error)).")
                                    return
                                }
                                recaptchaClient.set(.single(client))
                            }
                        }
                    }
                    
                    return (recaptchaClient.get()
                    |> take(1)
                    |> mapToSignal { recaptchaClient -> Signal<String?, NoError> in
                        return Signal { subscriber in
                            var recaptchaAction: RecaptchaAction?
                            switch method {
                            case "signup":
                                recaptchaAction = RecaptchaAction.signup
                            default:
                                break
                            }
                            
                            guard let recaptchaAction else {
                                subscriber.putNext(nil)
                                subscriber.putCompletion()
                                
                                return EmptyDisposable
                            }
                            recaptchaClient.execute(withAction: recaptchaAction) { token, error in
                                if let token {
                                    subscriber.putNext(token)
                                    Logger.shared.log("App \(self.episodeId)", "RecaptchaClient executed successfully")
                                } else {
                                    subscriber.putNext(nil)
                                    Logger.shared.log("App \(self.episodeId)", "RecaptchaClient execute error: \(String(describing: error))")
                                }
                                subscriber.putCompletion()
                            }
                            
                            return ActionDisposable {
                            }
                        }
                        |> runOn(Queue.mainQueue())
                    }).startStandalone(next: subscriber.putNext, error: subscriber.putError, completed: subscriber.putCompletion)
                }
                |> runOn(Queue.mainQueue())
            },
            autolockDeadine: autolockDeadine,
            encryptionProvider: OpenSSLEncryptionProvider(),
            deviceModelName: nil,
            useBetaFeatures: !buildConfig.isAppStoreBuild,
            isICloudEnabled: buildConfig.isICloudEnabled,
            // Only the main app passes a factory: extensions stay on MtProtoKit. Whether the Rust
            // engine runs is decided per account by resolveNetworkEngine (Debug Settings switch,
            // mtproto_engine_rust_disabled, the factory's own declines).
            networkEngineFactory: RustNetworkEngineFactory()
        )
        
        guard let appGroupUrl = maybeAppGroupUrl else {
            self.mainWindow?.presentNative(UIAlertController(title: nil, message: "Error 2", preferredStyle: .alert))
            return true
        }
        
        // Logging to a file is on by default only in debug-compiled and internal builds (the extensions
        // never looked at the receipt either). It used to be on for every build with a sandbox receipt
        // too (TestFlight and development-signed release builds), where it cost ~3 s of CPU per measured
        // session in unbuffered log writes and full MTProto descriptions; those builds now start with it
        // off, as App Store builds always have. A choice stored from Settings > Debug ("Log to File") or
        // the enableLog link always wins over this default (see the loggingSettings read below). A let per
        // configuration and no branch on it: either way round one configuration warns (never mutated, or
        // never executed), and TelegramUI builds with warnings as errors.
        #if DEBUG
        let logToFileByDefault = true
        #else
        let logToFileByDefault = buildConfig.isInternalBuild
        #endif
        
        LoggingSettings.defaultSettings = LoggingSettings(logToFile: logToFileByDefault, logToConsole: false, redactSensitiveData: true)
        
        let isUITest = CommandLine.arguments.contains("--ui-test")

        let rootPath: String
        if isUITest {
            let testDataPath = appGroupUrl.path + "/telegram-ui-tests-data"
            let _ = try? FileManager.default.removeItem(atPath: testDataPath)
            rootPath = rootPathForBasePath(testDataPath)
        } else {
            rootPath = rootPathForBasePath(appGroupUrl.path)
        }
        if !isUITest {
            performAppGroupUpgrades(appGroupPath: appGroupUrl.path, rootPath: rootPath)
        }
        
        let deviceSpecificEncryptionParameters = BuildConfig.deviceSpecificEncryptionParameters(rootPath, baseAppBundleId: baseAppBundleId)
        let encryptionParameters = ValueBoxEncryptionParameters(forceEncryptionIfNoSet: false, key: ValueBoxEncryptionParameters.Key(data: deviceSpecificEncryptionParameters.key)!, salt: ValueBoxEncryptionParameters.Salt(data: deviceSpecificEncryptionParameters.salt)!)
        
        TempBox.initializeShared(basePath: rootPath, processType: "app", launchSpecificId: Int64.random(in: Int64.min ... Int64.max))
        // Attachment copies a killed share extension left behind (up to a whole video each), on a
        // background queue.
        removeStaleShareItemFiles(parentPath: shareItemFilesPath(rootPath: rootPath))
        
        let writeAbilityTestFile = TempBox.shared.tempFile(fileName: "test.bin")
        var writeAbilityTestSuccess = true
        if let testFile = ManagedFile(queue: nil, path: writeAbilityTestFile.path, mode: .readwrite) {
            let bufferSize = 128 * 1024
            let randomBuffer = malloc(bufferSize)!
            defer {
                free(randomBuffer)
            }
            arc4random_buf(randomBuffer, bufferSize)
            var writtenBytes = 0
            while writtenBytes < 1024 * 1024 {
                let actualBytes = testFile.write(randomBuffer, count: bufferSize)
                writtenBytes += actualBytes
                if actualBytes != bufferSize {
                    writeAbilityTestSuccess = false
                    break
                }
            }
            testFile._unsafeClose()
            TempBox.shared.dispose(writeAbilityTestFile)
        } else {
            writeAbilityTestSuccess = false
        }
        
        if !writeAbilityTestSuccess {
            let alertController = UIAlertController(title: nil, message: "The device does not have sufficient free space.", preferredStyle: .alert)
            alertController.addAction(UIAlertAction(title: "OK", style: .default, handler: { _ in
                preconditionFailure()
            }))
            self.mainWindow?.presentNative(alertController)
            
            return true
        }
        
        let legacyLogs: [String] = [
            "broadcast-logs",
            "siri-logs",
            "widget-logs",
            "notificationcontent-logs",
            "notification-logs"
        ]
        for item in legacyLogs {
            let _ = try? FileManager.default.removeItem(atPath: "\(rootPath)/\(item)")
        }
        
        let logsPath = rootPath + "/logs/app-logs"
        let _ = try? FileManager.default.createDirectory(atPath: logsPath, withIntermediateDirectories: true, attributes: nil)
        Logger.setSharedLogger(Logger(rootPath: rootPath, basePath: logsPath))
        self.startDiskWriteReports(ledgerPath: rootPath + "/logs/disk-writes.json")

        setManagedAudioSessionLogger({ s in
            Logger.shared.log("ManagedAudioSession", s)
            Logger.shared.shortLog("ManagedAudioSession", s)
        })
        
        if let contents = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: rootPath + "/accounts-metadata"), includingPropertiesForKeys: nil, options: [.skipsSubdirectoryDescendants]) {
            for url in contents {
                Logger.shared.log("App \(self.episodeId)", "metadata: \(url.path)")
            }
        }
        
        if let contents = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: rootPath), includingPropertiesForKeys: nil, options: [.skipsSubdirectoryDescendants]) {
            for url in contents {
                Logger.shared.log("App \(self.episodeId)", "root: \(url.path)")
                if url.lastPathComponent.hasPrefix("account-") {
                    if let subcontents = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsSubdirectoryDescendants]) {
                        for suburl in subcontents {
                            Logger.shared.log("App \(self.episodeId)", "account \(url.lastPathComponent): \(suburl.path)")
                        }
                    }
                }
            }
        }
        
        //ASDisableLogging()
        
        initializeLegacyComponents(application: application, currentSizeClassGetter: {
            return UIUserInterfaceSizeClass.compact
        }, currentHorizontalClassGetter: {
            return UIUserInterfaceSizeClass.compact
        }, documentsPath: legacyDocumentsPath(), currentApplicationBounds: {
            return mainWindowScreenBounds
        }, canOpenUrl: { url in
            return UIApplication.shared.canOpenURL(url)
        }, openUrl: { url in
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        })
        setContextMenuControllerProvider { arguments in
            return ContextMenuControllerImpl(arguments)
        }
        
        if #available(iOS 10.0, *) {
            UNUserNotificationCenter.current().delegate = self
        }
        
        GlobalExperimentalSettings.isAppStoreBuild = buildConfig.isAppStoreBuild
        GlobalExperimentalSettings.enableFeed = false
        
        var hasActiveCalls: Signal<Bool, NoError> = .single(false)
        if CallKitIntegration.isAvailable, let callKitIntegration = CallKitIntegration.shared {
            hasActiveCalls = callKitIntegration.hasActiveCalls
        }
        self.hasActiveAudioSession.set(
            combineLatest(queue: .mainQueue(),
                hasActiveCalls,
                MediaManagerImpl.globalAudioSession.isActive()
            )
            |> map { hasActiveCalls, isActive -> Bool in
                return hasActiveCalls || isActive
            }
            |> distinctUntilChanged
        )
        
        let applicationBindings = TelegramApplicationBindings(isMainApp: true, appBundleId: baseAppBundleId, appBuildType: buildConfig.isAppStoreBuild ? .public : .internal, containerPath: appGroupUrl.path, appSpecificScheme: buildConfig.appSpecificUrlScheme, openUrl: { url in
            var parsedUrl = URL(string: url)
            if let parsed = parsedUrl {
                if parsed.scheme == nil || parsed.scheme!.isEmpty {
                    parsedUrl = URL(string: "https://\(url)")
                }
                if parsed.scheme == "tg" {
                    return
                }
            }
            
            if let parsedUrl = parsedUrl {
                UIApplication.shared.open(parsedUrl, options: [:], completionHandler: nil)
            } else if let escapedUrl = url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed), let parsedUrl = URL(string: escapedUrl) {
                UIApplication.shared.open(parsedUrl, options: [:], completionHandler: nil)
            }
        }, openUniversalUrl: { url, completion in
            if #available(iOS 10.0, *) {
                var parsedUrl = URL(string: url)
                if let parsed = parsedUrl {
                    if parsed.scheme == nil || parsed.scheme!.isEmpty {
                        parsedUrl = URL(string: "https://\(url)")
                    }
                }
                
                if let parsedUrl = parsedUrl {
                    return UIApplication.shared.open(parsedUrl, options: [UIApplication.OpenExternalURLOptionsKey.universalLinksOnly: true as NSNumber], completionHandler: { value in
                        completion.completion(value)
                    })
                } else if let escapedUrl = (url.removingPercentEncoding ?? url).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed), let parsedUrl = URL(string: escapedUrl) {
                    return UIApplication.shared.open(parsedUrl, options: [UIApplication.OpenExternalURLOptionsKey.universalLinksOnly: true as NSNumber], completionHandler: { value in
                        completion.completion(value)
                    })
                } else {
                    completion.completion(false)
                }
            } else {
                completion.completion(false)
            }
        }, canOpenUrl: { url in
            var parsedUrl = URL(string: url)
            if let parsed = parsedUrl {
                if parsed.scheme == nil || parsed.scheme!.isEmpty {
                    parsedUrl = URL(string: "https://\(url)")
                }
            }
            if let parsedUrl = parsedUrl {
                return UIApplication.shared.canOpenURL(parsedUrl)
            } else if let escapedUrl = url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed), let parsedUrl = URL(string: escapedUrl) {
                return UIApplication.shared.canOpenURL(parsedUrl)
            } else {
                return false
            }
        }, getTopWindow: {
            for window in application.allWindowSceneWindows.reversed() {
                if window === self.window || window === statusBarHost.keyboardWindow {
                    return window
                }
            }
            return application.allWindowSceneWindows.last
        }, displayNotification: { text in
        }, applicationInForeground: self.isInForegroundPromise.get(),
           applicationIsActive: self.isActivePromise.get(),
           clearMessageNotifications: { ids in
            for id in ids {
                self.clearNotificationsManager?.append(id)
            }
        }, pushIdleTimerExtension: {
            let disposable = MetaDisposable()
            Queue.mainQueue().async {
                let wasEmpty = self.idleTimerExtensionSubscribers.isEmpty
                let index = self.idleTimerExtensionSubscribers.add(Void())
                
                if wasEmpty {
                    application.isIdleTimerDisabled = true
                }
                
                disposable.set(ActionDisposable {
                    Queue.mainQueue().async {
                        self.idleTimerExtensionSubscribers.remove(index)
                        if self.idleTimerExtensionSubscribers.isEmpty {
                            application.isIdleTimerDisabled = false
                        }
                    }
                })
            }
            
            return disposable
        }, openSettings: {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            }
        }, openAppStorePage: {
            let appStoreId = buildConfig.appStoreId
            if let url = URL(string: "itms-apps://itunes.apple.com/app/id\(appStoreId)") {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            }
        }, openSubscriptions: {
            if #available(iOS 15, *), let scene = self.mainWindow?.preferredWindowScene {
                let _ = Task {
                    try await AppStore.showManageSubscriptions(in: scene)
                }
            } else if let url = URL(string: "https://apps.apple.com/account/subscriptions") {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            }
        }, registerForNotifications: { completion in
            Logger.shared.log("App \(self.episodeId)", "register for notifications begin")
            let _ = (self.context.get()
            |> take(1)
            |> deliverOnMainQueue).start(next: { context in
                if let context = context {
                    Logger.shared.log("App \(self.episodeId)", "register for notifications initiate")
                    self.registerForNotifications(context: context.context, authorize: true, completion: completion)
                }
            })
        }, requestSiriAuthorization: { completion in
            if #available(iOS 10, *) {
                INPreferences.requestSiriAuthorization { status in
                    if case .authorized = status {
                        completion(true)
                    } else {
                        completion(false)
                    }
                }
            } else {
                completion(false)
            }
        }, siriAuthorization: {
            if buildConfig.isSiriEnabled {
                if #available(iOS 10, *) {
                    switch INPreferences.siriAuthorizationStatus() {
                    case .authorized:
                        return .allowed
                    case .denied, .restricted:
                        return .denied
                    case .notDetermined:
                        return .notDetermined
                    @unknown default:
                        return .notDetermined
                    }
                } else {
                    return .denied
                }
            } else {
                return .denied
            }
        }, getWindowHost: {
            return self.nativeWindow
        }, presentNativeController: { controller in
            self.window?.rootViewController?.present(controller, animated: true, completion: nil)
        }, dismissNativeController: {
            self.window?.rootViewController?.dismiss(animated: true, completion: nil)
        }, getAvailableAlternateIcons: {
            if #available(iOS 10.3, *) {
                // Only Nanogram's own icons, all free. Sphere is the primary icon (choosing it clears the
                // alternate icon). Telegram's icons are not bundled (Telegram/BUILD, alternate_icon_folders).
                // The alternates' images are rendered from Telegram/Telegram-iOS/AlternateIconSources.
                return [
                    PresentationAppIcon(name: "NanogramSphere", imageName: "NanogramSphere", isDefault: true),
                    PresentationAppIcon(name: "NanogramComet", imageName: "NanogramComet"),
                    PresentationAppIcon(name: "NanogramWhite", imageName: "NanogramWhite"),
                    PresentationAppIcon(name: "NanogramGlass", imageName: "NanogramGlass"),
                    PresentationAppIcon(name: "NanogramOrbit", imageName: "NanogramOrbit"),
                    PresentationAppIcon(name: "NanogramBubble", imageName: "NanogramBubble"),
                    PresentationAppIcon(name: "NanogramSpeed", imageName: "NanogramSpeed"),
                    PresentationAppIcon(name: "NanogramSplitN", imageName: "NanogramSplitN"),
                    PresentationAppIcon(name: "NanogramRibbon", imageName: "NanogramRibbon"),
                    PresentationAppIcon(name: "NanogramDot", imageName: "NanogramDot"),
                    PresentationAppIcon(name: "NanogramNight", imageName: "NanogramNight"),
                    PresentationAppIcon(name: "NanogramClassic", imageName: "NanogramClassic"),
                    PresentationAppIcon(name: "NanogramDash", imageName: "NanogramDash"),
                    PresentationAppIcon(name: "NanogramForward", imageName: "NanogramForward"),
                    PresentationAppIcon(name: "NanogramStreak", imageName: "NanogramStreak")
                ]
            } else {
                return []
            }
        }, getAlternateIconName: {
            if #available(iOS 10.3, *) {
                return application.alternateIconName
            } else {
                return nil
            }
        }, requestSetAlternateIconName: { name, completion in
            application.setAlternateIconName(name, completionHandler: { error in
                if let error = error {
                   Logger.shared.log("App \(self.episodeId)", "failed to set alternate icon with error \(error.localizedDescription)")
                }
                completion(error == nil)
            })
        }, forceOrientation: { orientation in
            let value = orientation.rawValue
            if #available(iOSApplicationExtension 16.0, iOS 16.0, *) {
                let windowScene = self.mainWindow?.preferredWindowScene
                var interfaceOrientations: UIInterfaceOrientationMask = []
                switch orientation {
                case .portrait:
                    interfaceOrientations = .portrait
                case .landscapeLeft:
                    interfaceOrientations = .landscapeLeft
                case .landscapeRight:
                    interfaceOrientations = .landscapeRight
                case .portraitUpsideDown:
                    interfaceOrientations = .portraitUpsideDown
                case .unknown:
                    interfaceOrientations = .portrait
                @unknown default:
                    interfaceOrientations = .portrait
                }
                windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: interfaceOrientations))
            } else {
                UIDevice.current.setValue(value, forKey: "orientation")
                UINavigationController.attemptRotationToDeviceOrientation()
            }
        })
        
        let accountManager: AccountManager<TelegramAccountManagerTypes> = setupAccountManager(basePath: rootPath + "/accounts-metadata", isTemporary: false, isReadOnly: false, useCaches: true, removeDatabaseOnError: true, resetLocalSecrets: {
            try resetWalletLocalSecrets()
        })
        self.accountManager = accountManager

        telegramUIDeclareEncodables()
        initializeAccountManagement()

        if isUITest,
           let deleteIdx = CommandLine.arguments.firstIndex(of: "--delete-test-account"),
           deleteIdx + 1 < CommandLine.arguments.count
        {
            let phone = CommandLine.arguments[deleteIdx + 1]
            let digits = phone.hasPrefix("+") ? String(phone.dropFirst()) : phone
            guard digits.count == 10, digits.hasPrefix("99966") else {
                preconditionFailure("--delete-test-account phone must match 99966XYYYY")
            }
            let dcDigit = digits[digits.index(digits.startIndex, offsetBy: 5)]
            let phoneCode = String(repeating: dcDigit, count: 5)

            let window = self.window!

            NSLog("[DeleteAccount] starting for +\(digits)")
            let _ = test_loginAndDeleteAccount(
                rootPath: rootPath,
                accountManager: accountManager,
                networkArguments: networkArguments,
                encryptionParameters: encryptionParameters,
                phoneNumber: "+\(digits)",
                phoneCode: phoneCode
            ).start(error: { error in
                NSLog("[DeleteAccount] error: \(error)")
                preconditionFailure("test_loginAndDeleteAccount failed")
            }, completed: {
                NSLog("[DeleteAccount] completed")
                DispatchQueue.main.async {
                    window.accessibilityIdentifier = "DeleteAccount.Success"
                }
            })

            return true
        }

        let pushRegistry = PKPushRegistry(queue: .main)
        if #available(iOS 9.0, *) {
            pushRegistry.desiredPushTypes = Set([.voIP])
        }
        self.pushRegistry = pushRegistry
        pushRegistry.delegate = self

        self.accountManagerState = extractAccountManagerState(records: accountManager._internalAccountRecordsSync())
        let _ = (accountManager.accountRecords()
        |> deliverOnMainQueue).start(next: { view in
            self.accountManagerState = extractAccountManagerState(records: view)
        })

        var systemUserInterfaceStyle: WindowUserInterfaceStyle = .light
        if #available(iOS 13.0, *) {
            if let traitCollection = window.rootViewController?.traitCollection {
                systemUserInterfaceStyle = WindowUserInterfaceStyle(style: traitCollection.userInterfaceStyle)
            }
        }
        
        let sharedContextSignal = currentPresentationDataAndSettings(accountManager: accountManager, systemUserInterfaceStyle: systemUserInterfaceStyle)
        |> map { initialPresentationDataAndSettings -> (AccountManager, InitialPresentationDataAndSettings) in
            return (accountManager, initialPresentationDataAndSettings)
        }
        |> deliverOnMainQueue
        |> mapToSignal { [self] accountManager, initialPresentationDataAndSettings -> Signal<(SharedApplicationContext, LoggingSettings), NoError> in
            self.mainWindow?.hostView.containerView.backgroundColor =  initialPresentationDataAndSettings.presentationData.theme.chatList.backgroundColor
            
            let legacyBasePath = appGroupUrl.path
            
            let presentationDataPromise = Promise<PresentationData>()
            let appLockContext = AppLockContextImpl(rootPath: rootPath, window: self.mainWindow!, rootController: self.window?.rootViewController, applicationBindings: applicationBindings, accountManager: accountManager, presentationDataSignal: presentationDataPromise.get(), lockIconInitialFrame: {
                return (self.mainWindow?.viewController as? TelegramRootController)?.chatListController?.lockViewFrame
            })
            
            var setPresentationCall: ((PresentationCall?) -> Void)?
            let sharedContext = SharedAccountContextImpl(mainWindow: self.mainWindow, sharedContainerPath: legacyBasePath, basePath: rootPath, encryptionParameters: encryptionParameters, accountManager: accountManager, appLockContext: appLockContext, notificationController: nil, applicationBindings: applicationBindings, initialPresentationDataAndSettings: initialPresentationDataAndSettings, networkArguments: networkArguments, hasInAppPurchases: buildConfig.isAppStoreBuild && buildConfig.apiId == 1, rootPath: rootPath, legacyBasePath: legacyBasePath, apsNotificationToken: self.notificationTokenPromise.get() |> map(Optional.init), voipNotificationToken: self.voipTokenPromise.get() |> map(Optional.init), firebaseSecretStream: self.firebaseSecretStream.get(), setNotificationCall: { call in
                setPresentationCall?(call)
            }, navigateToChat: { accountId, peerId, messageId, alwaysKeepMessageId in
                self.openChatWhenReady(accountId: accountId, peerId: peerId, threadId: nil, messageId: messageId, storyId: nil, alwaysKeepMessageId: alwaysKeepMessageId)
            }, displayUpgradeProgress: { progress in
                if let progress = progress {
                    if self.dataImportSplash == nil {
                        self.dataImportSplash = makeLegacyDataImportSplash(theme: initialPresentationDataAndSettings.presentationData.theme, strings: initialPresentationDataAndSettings.presentationData.strings)
                        self.dataImportSplash?.serviceAction = {
                            self.debugPressed()
                        }
                        self.mainWindow.coveringView = self.dataImportSplash
                    }
                    self.dataImportSplash?.progress = (.generic, progress)
                } else if let dataImportSplash = self.dataImportSplash {
                    self.dataImportSplash = nil
                    if self.mainWindow.coveringView === dataImportSplash {
                        self.mainWindow.coveringView = nil
                    }
                }
            }, appDelegate: self, testingEnvironment: isUITest)
            navigationBarOverflowMenuPresenter = { [weak sharedContext] sourceView, items in
                guard let sharedContext, let mainWindow = sharedContext.mainWindow else {
                    return
                }
                let presentationData = sharedContext.currentPresentationData.with { $0 }
                let menuItems: [ContextMenuItem] = items.map { item in
                    return .action(ContextMenuActionItem(text: item.title, icon: { theme in
                        guard let image = item.image ?? item.iconName.flatMap({ UIImage(bundleImageName: $0) }) else {
                            return nil
                        }
                        return generateScaledImage(image: generateTintedImage(image: image, color: theme.contextMenu.primaryColor), size: CGSize(width: 24.0, height: 24.0), opaque: false)
                    }, action: { _, f in
                        f(.default)
                        item.action(sourceView)
                    }))
                }
                let contextController = makeContextController(presentationData: presentationData, source: .reference(NavigationBarOverflowMenuReferenceSource(sourceView: sourceView)), items: .single(ContextController.Items(content: .list(menuItems))), gesture: nil)
                mainWindow.presentInGlobalOverlay(contextController)
            }
            
            presentationDataPromise.set(sharedContext.presentationData)
            #if targetEnvironment(simulator)
            if CommandLine.arguments.contains("--context-menu-morph-gallery") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    self?.mainWindow.present(ContextMenuMorphDebugController(), on: .root)
                }
            }
            #endif
            
            sharedContext.presentGlobalController = { [weak self] c, a in
                guard let strongSelf = self else {
                    return
                }
                strongSelf.mainWindow.present(c, on: .root)
            }
            sharedContext.presentCrossfadeController = { [weak self] in
                guard let strongSelf = self else {
                    return
                }
                var exists = false
                strongSelf.mainWindow.forEachViewController({ controller in
                    if controller is ThemeSettingsCrossfadeController || controller is ThemeSettingsController || controller is ThemePreviewController {
                        exists = true
                    }
                    return true
                })
                
                if !exists {
                    strongSelf.mainWindow.present(ThemeSettingsCrossfadeController(), on: .root)
                }
            }
            
            let notificationManager = SharedNotificationManager(episodeId: self.episodeId, application: application, clearNotificationsManager: clearNotificationsManager, inForeground: applicationBindings.applicationInForeground, accounts: sharedContext.activeAccountContexts |> map { primary, accounts, _ in accounts.map({ ($0.1.account, $0.1.account.id == primary?.account.id) }) }, pollLiveLocationOnce: { accountId in
                let _ = (self.context.get()
                |> filter {
                    return $0 != nil
                }
                |> take(1)
                |> deliverOnMainQueue).start(next: { context in
                    if let context = context, context.context.account.id == accountId {
                        context.context.liveLocationManager?.pollOnce()
                    }
                })
            })
            setPresentationCall = { call in
                notificationManager.setNotificationCall(call, strings: sharedContext.currentPresentationData.with({ $0 }).strings)
            }
            let liveLocationPolling = self.context.get()
            |> mapToSignal { context -> Signal<AccountRecordId?, NoError> in
                if let context = context, let liveLocationManager = context.context.liveLocationManager {
                    let accountId = context.context.account.id
                    return combineLatest(queue: .mainQueue(),
                        liveLocationManager.isPolling,
                        liveLocationManager.hasBackgroundTasks
                    )
                    |> map { isPolling, hasBackgroundTasks -> Bool in
                        return isPolling || hasBackgroundTasks
                    }
                    |> distinctUntilChanged
                    |> map { value -> AccountRecordId? in
                        if value {
                            return accountId
                        } else {
                            return nil
                        }
                    }
                } else {
                    return .single(nil)
                }
            }
            
            let wakeupManager = SharedWakeupManager(beginBackgroundTask: { name, expiration in
                let id = application.beginBackgroundTask(withName: name, expirationHandler: expiration)
                Logger.shared.log("App \(self.episodeId)", "Begin background task \(name): \(id)")
                print("App \(self.episodeId)", "Begin background task \(name): \(id)")
                return id
            }, endBackgroundTask: { id in
                print("App \(self.episodeId)", "End background task \(id)")
                Logger.shared.log("App \(self.episodeId)", "End background task \(id)")
                application.endBackgroundTask(id)
            }, backgroundTimeRemaining: { application.backgroundTimeRemaining }, acquireIdleExtension: {
                return applicationBindings.pushIdleTimerExtension()
            }, activeAccounts: sharedContext.activeAccountContexts |> map { ($0.0?.account, $0.1.map { ($0.0, $0.1.account) }) }, liveLocationPolling: liveLocationPolling, watchTasks: .single(nil), inForeground: applicationBindings.applicationInForeground, hasActiveAudioSession: self.hasActiveAudioSession.get(), notificationManager: notificationManager, mediaManager: sharedContext.mediaManager, callManager: sharedContext.callManager, accountUserInterfaceInUse: { id in
                return sharedContext.accountUserInterfaceInUse(id)
            }, presentationData: {
                return sharedContext.currentPresentationData.with({ $0 })
            })
            let sharedApplicationContext = SharedApplicationContext(sharedContext: sharedContext, notificationManager: notificationManager, wakeupManager: wakeupManager)
            sharedApplicationContext.sharedContext.mediaManager.overlayMediaManager.attachOverlayMediaController(sharedApplicationContext.overlayMediaController)
            
            return accountManager.transaction { transaction -> (SharedApplicationContext, LoggingSettings) in
                return (sharedApplicationContext, transaction.getSharedData(SharedDataKeys.loggingSettings)?.get(LoggingSettings.self) ?? LoggingSettings.defaultSettings)
            }
        }
        self.sharedContextPromise.set(sharedContextSignal
        |> mapToSignal { sharedApplicationContext, loggingSettings -> Signal<SharedApplicationContext, NoError> in
            Logger.shared.logToFile = loggingSettings.logToFile
            Logger.shared.logToConsole = loggingSettings.logToConsole
            Logger.shared.redactSensitiveData = loggingSettings.redactSensitiveData
            
            return .single(sharedApplicationContext)
        })
            
        self.context.set(self.sharedContextPromise.get()
        |> deliverOnMainQueue
        |> mapToSignal { sharedApplicationContext -> Signal<AuthorizedApplicationContext?, NoError> in
            return sharedApplicationContext.sharedContext.activeAccountContexts
            |> map { primary, _, _ -> AccountContext? in
                return primary
            }
            |> distinctUntilChanged(isEqual: { lhs, rhs in
                if lhs !== rhs {
                    return false
                }
                return true
            })
            |> mapToSignal { context -> Signal<(AccountContext, CallListSettings)?, NoError> in
                return sharedApplicationContext.sharedContext.accountManager.transaction { transaction -> CallListSettings? in
                    return transaction.getSharedData(ApplicationSpecificSharedDataKeys.callListSettings)?.get(CallListSettings.self)
                }
                |> reduceLeft(value: nil) { current, updated -> CallListSettings? in
                    var result: CallListSettings?
                    if let updated = updated {
                        result = updated
                    } else if let current = current {
                        result = current
                    }
                    return result
                }
                |> map { callListSettings -> (AccountContext, CallListSettings)? in
                    if let context = context {
                        return (context, callListSettings ?? .defaultSettings)
                    } else {
                        return nil
                    }
                }
            }
            |> deliverOnMainQueue
            |> map { accountAndSettings -> AuthorizedApplicationContext? in
                return accountAndSettings.flatMap { context, callListSettings in
                    return AuthorizedApplicationContext(sharedApplicationContext: sharedApplicationContext, mainWindow: self.mainWindow, context: context as! AccountContextImpl, accountManager: sharedApplicationContext.sharedContext.accountManager, showCallsTab: callListSettings.showTab, reinitializedNotificationSettings: {
                        let _ = (self.context.get()
                        |> take(1)
                        |> deliverOnMainQueue).start(next: { context in
                            if let context = context {
                                self.registerForNotifications(context: context.context, authorize: false)
                            }
                        })
                    })
                }
            }
        })
        
        self.authContext.set(self.sharedContextPromise.get()
        |> deliverOnMainQueue
        |> mapToSignal { sharedApplicationContext -> Signal<UnauthorizedApplicationContext?, NoError> in
            return sharedApplicationContext.sharedContext.activeAccountContexts
            |> map { primary, accounts, auth -> (AccountContext?, UnauthorizedAccount, [AccountContext])? in
                if let auth = auth {
                    return (primary, auth, Array(accounts.map({ $0.1 })))
                } else {
                    return nil
                }
            }
            |> distinctUntilChanged(isEqual: { lhs, rhs in
                if lhs?.1 !== rhs?.1 {
                    return false
                }
                return true
            })
            |> mapToSignal { authAndAccounts -> Signal<(UnauthorizedAccount, ((String, AccountRecordId, Bool)?, [(String, AccountRecordId, Bool)]))?, NoError> in
                if let (primary, auth, accounts) = authAndAccounts {
                    let phoneNumbers = combineLatest(accounts.map { context -> Signal<(AccountRecordId, String, Bool)?, NoError> in
                        return context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: context.account.peerId))
                        |> map { peer -> (AccountRecordId, String, Bool)? in
                            if case let .user(user) = peer, let phone = user.phone {
                                return (context.account.id, phone, context.account.testingEnvironment)
                            } else {
                                return nil
                            }
                        }
                    })
                    return phoneNumbers
                    |> map { phoneNumbers -> (UnauthorizedAccount, ((String, AccountRecordId, Bool)?, [(String, AccountRecordId, Bool)]))? in
                        var primaryNumber: (String, AccountRecordId, Bool)?
                        if let primary = primary {
                            for idAndNumber in phoneNumbers {
                                if let (id, number, testingEnvironment) = idAndNumber, id == primary.account.id {
                                    primaryNumber = (number, id, testingEnvironment)
                                    break
                                }
                            }
                        }
                        return (auth, (primaryNumber, phoneNumbers.compactMap({ $0.flatMap({ ($0.1, $0.0, $0.2) }) })))
                    }
                } else {
                    return .single(nil)
                }
            }
            |> deliverOnMainQueue
            |> map { accountAndSettings -> UnauthorizedApplicationContext? in
                return accountAndSettings.flatMap { account, otherAccountPhoneNumbers in
                    return UnauthorizedApplicationContext(apiId: buildConfig.apiId, apiHash: buildConfig.apiHash, sharedContext: sharedApplicationContext.sharedContext, account: account, otherAccountPhoneNumbers: otherAccountPhoneNumbers)
                }
            }
        })
        
        let contextReadyDisposable = MetaDisposable()
        
        let startTime = CFAbsoluteTimeGetCurrent()
        self.contextDisposable.set((self.context.get()
        |> deliverOnMainQueue).start(next: { context in
            print("Application: context took \(CFAbsoluteTimeGetCurrent() - startTime) to become available")
            
            var network: Network?
            if let context = context {
                network = context.context.account.network
            }
            
            Logger.shared.log("App \(self.episodeId)", "received context \(String(describing: context)) account \(String(describing: context?.context.account.id)) network \(String(describing: network))")
            
            let firstTime = self.contextValue == nil
            if let contextValue = self.contextValue {
                contextValue.passcodeController?.dismiss()
                contextValue.context.account.shouldExplicitelyKeepWorkerConnections.set(.single(false))
                contextValue.context.account.shouldKeepBackgroundDownloadConnections.set(.single(false))
            }
            self.crashReportPromptDisposable.set(nil)
            self.contextValue = context
            if #available(iOS 26.0, *), mainMenuIsInstalled(deviceType: self.mainWindow?.deviceType ?? .phone, available: true) {
                // The menu titles are the account's language from here on.
                MainMenuInstaller.setNeedsRebuild()
            }
            if let context = context {
                setupLegacyComponents(context: context.context)
                let isReady = context.isReady.get()
                contextReadyDisposable.set((isReady
                |> filter { $0 }
                |> take(1)
                |> deliverOnMainQueue).start(next: { _ in
                    let readyTime = CFAbsoluteTimeGetCurrent() - startTime
                    if readyTime > 0.5 {
                        print("Application: context took \(readyTime) to become ready")
                    }
                    print("Launch to ready took \((CFAbsoluteTimeGetCurrent() - launchStartTime) * 1000.0) ms")

                    self.mainWindow.debugAction = nil
                    self.mainWindow.viewController = context.rootController
                    
                    if firstTime {
                        let layer = context.rootController.view.layer
                        layer.allowsGroupOpacity = true
                        layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2, completion: { [weak layer] _ in
                            if let layer = layer {
                                layer.allowsGroupOpacity = false
                            }
                        })
                    }
                    self.mainWindow.topLevelOverlayControllers = [context.sharedApplicationContext.overlayMediaController, context.notificationController]
                    (context.context.sharedContext as? SharedAccountContextImpl)?.notificationController = context.notificationController
                    var authorizeNotifications = true
                    if #available(iOS 10.0, *) {
                        authorizeNotifications = false
                    }
                    self.registerForNotifications(context: context.context, authorize: authorizeNotifications)
                    
                    self.resetIntentsIfNeeded(context: context.context)
                    self.crashReportPromptDisposable.set(setupCrashReportPrompt(context: context.context, isInternalBuild: buildConfig.isInternalBuild, navigationController: context.rootController, present: { [weak appDelegate = self, weak applicationContext = context] controller in
                        guard let appDelegate, let applicationContext, appDelegate.contextValue === applicationContext else { return }
                        appDelegate.mainWindow.present(controller, on: .root)
                    }))
                }))
            } else {
                self.mainWindow.viewController = nil
                self.mainWindow.topLevelOverlayControllers = []
                contextReadyDisposable.set(nil)
            }
        }))
        
        let authContextReadyDisposable = MetaDisposable()
        
        self.authContextDisposable.set((self.authContext.get()
        |> deliverOnMainQueue).start(next: { [weak self] context in
            guard let self else {
                return
            }

            var network: Network?
            if let context = context {
                network = context.account.network
            }
            
            Logger.shared.log("App \(self.episodeId)", "received auth context \(String(describing: context)) account \(String(describing: context?.account.id)) network \(String(describing: network))")
            
            if let authContextValue = self.authContextValue {
                authContextValue.account.shouldBeServiceTaskMaster.set(.single(.never))
                if authContextValue.authorizationCompleted {
                    let accountId = authContextValue.account.id
                    let _ = (self.context.get()
                    |> filter { context in
                        return context?.context.account.id == accountId
                    }
                    |> take(1)
                    |> timeout(4.0, queue: .mainQueue(), alternate: .complete())
                    |> deliverOnMainQueue).start(completed: {
                        Queue.mainQueue().after(0.75) {
                            authContextValue.rootController.view.endEditing(true)
                            authContextValue.rootController.dismiss()
                        }
                    })
                } else {
                    authContextValue.rootController.view.endEditing(true)
                    authContextValue.rootController.dismiss()
                }
            }
            self.authContextValue = context
            if let context = context {
                let presentationData = context.sharedContext.currentPresentationData.with({ $0 })
                
                let progressSignal = Signal<Never, NoError> { [weak self] subscriber in
                    let statusController = OverlayStatusController(theme: presentationData.theme, type: .loading(cancelled: nil))
                    self?.mainWindow.present(statusController, on: .root)
                    return ActionDisposable { [weak statusController] in
                        Queue.mainQueue().async() {
                            statusController?.dismiss()
                        }
                    }
                }
                |> runOn(Queue.mainQueue())
                |> delay(0.5, queue: Queue.mainQueue())
                let progressDisposable = progressSignal.start()
                
                let isReady: Signal<Bool, NoError> = context.isReady.get()
                authContextReadyDisposable.set((isReady
                |> filter { $0 }
                |> take(1)
                |> deliverOnMainQueue).start(next: { _ in
                    progressDisposable.dispose()
                    self.mainWindow.present(context.rootController, on: .root)
                }))
            } else {
                authContextReadyDisposable.set(nil)
            }
        }))


        let logoutDataSignal: Signal<(AccountManager, Set<PeerId>), NoError> = self.sharedContextPromise.get()
        |> take(1)
        |> mapToSignal { sharedContext -> Signal<(AccountManager<TelegramAccountManagerTypes>, Set<PeerId>), NoError> in
            return sharedContext.sharedContext.activeAccountContexts
            |> map { _, accounts, _ -> Set<PeerId> in
                return Set(accounts.map { $0.1.account.peerId })
            }
            |> reduceLeft(value: Set<PeerId>()) { current, updated, emit in
                if !current.isEmpty {
                    emit(current.subtracting(current.intersection(updated)))
                }
                return updated
            }
            |> map { loggedOutAccountPeerIds -> (AccountManager<TelegramAccountManagerTypes>, Set<PeerId>) in
                return (sharedContext.sharedContext.accountManager, loggedOutAccountPeerIds)
            }
        }

        self.logoutDisposable.set(logoutDataSignal.start(next: { accountManager, loggedOutAccountPeerIds in
            let _ = (updateIntentsSettingsInteractively(accountManager: accountManager) { current in
                var updated = current
                for peerId in loggedOutAccountPeerIds {
                    deleteAllStoryDrafts(peerId: peerId)
                    if peerId == updated.account {
                        deleteAllSendMessageIntents()
                        updated = updated.withUpdatedAccount(nil)
                        break
                    }
                }
                return updated
            }).start()
        }))
        
        self.resetBadge()
        
        if #available(iOS 9.1, *) {
            self.quickActionsDisposable.set((self.context.get()
            |> mapToSignal { context -> Signal<[ApplicationShortcutItem], NoError> in
                if let context = context {
                    let presentationData = context.context.sharedContext.currentPresentationData.with { $0 }
                    
                    return activeAccountsAndPeers(context: context.context)
                    |> take(1)
                    |> map { primaryAndAccounts -> (AccountContext, EnginePeer, Int32)? in
                        return primaryAndAccounts.1.first
                    }
                    |> map { accountAndPeer -> String? in
                        if let (_, peer, _) = accountAndPeer {
                            return peer.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder)
                        } else {
                            return nil
                        }
                    } |> mapToSignal { otherAccountName -> Signal<[ApplicationShortcutItem], NoError> in
                        let presentationData = context.context.sharedContext.currentPresentationData.with { $0 }
                        return .single(applicationShortcutItems(strings: presentationData.strings, otherAccountName: otherAccountName))
                    }
                } else {
                    return .single([])
                }
            }
            |> distinctUntilChanged
            |> deliverOnMainQueue).start(next: { items in
                if items.isEmpty {
                    UIApplication.shared.shortcutItems = nil
                } else {
                    UIApplication.shared.shortcutItems = items.map({ $0.shortcutItem() })
                }
            }))
        }
        
        let _ = self.isInForegroundPromise.get().start(next: { value in
            Logger.shared.log("App \(self.episodeId)", "isInForeground = \(value)")
            let _ = self.maintenanceIsInForeground.swap(value)
        })
        let _ = self.isActivePromise.get().start(next: { value in
            Logger.shared.log("App \(self.episodeId)", "isActive = \(value)")
            let _ = self.maintenanceIsActive.swap(value)
        })
        
        if application.applicationState == .active {
            self.isInForegroundValue = true
            self.isInForegroundPromise.set(true)
            self.isActiveValue = true
            self.isActivePromise.set(true)
            
            SharedDisplayLinkDriver.shared.updateForegroundState(self.isActiveValue)
            
            self.runForegroundTasks()
        }
        
        
        DeviceProximityManager.shared().proximityChanged = { [weak self] value in
            if let strongSelf = self {
                strongSelf.mainWindow.setProximityDimHidden(!value)
            }
        }
        
        #if canImport(AppCenter)
        if !buildConfig.isAppStoreBuild, let appCenterId = buildConfig.appCenterId, !appCenterId.isEmpty {
            AppCenter.start(withAppSecret: buildConfig.appCenterId, services: [
                Crashes.self
            ])
        }
        #endif
        
        if #available(iOS 13.0, *) {
            let cleanupTaskId = "\(baseAppBundleId).cleanup"
            
            BGTaskScheduler.shared.register(forTaskWithIdentifier: cleanupTaskId, using: DispatchQueue.main) { task in
                Logger.shared.log("App \(self.episodeId)", "Executing cleanup task")
                
                // Main queue from here on. `expired` is also read on the Postbox queue (VACUUM gate).
                let expired = Atomic<Bool>(value: false)
                var isFinished = false
                var wakeupManager: SharedWakeupManager?
                let disposable = MetaDisposable()
                
                // Ends the task after writes are paused: the running transaction commits first (or the drain
                // timeout passes), so the app is not suspended with a database file locked.
                let finish: (Bool) -> Void = { success in
                    if isFinished {
                        return
                    }
                    isFinished = true
                    let end = {
                        task.setTaskCompleted(success: success)
                    }
                    if let wakeupManager {
                        wakeupManager.endCleanupProcessingTask(end)
                    } else {
                        end()
                    }
                }
                
                task.expirationHandler = {
                    let _ = expired.swap(true)
                    // A VACUUM that is running rolls back now instead of holding the file lock into suspension.
                    self.interruptDatabaseMaintenance()
                    disposable.dispose()
                    finish(false)
                }
                
                let _ = (self.sharedContextPromise.get()
                |> take(1)
                |> deliverOnMainQueue).start(next: { sharedApplicationContext in
                    if isFinished {
                        return
                    }
                    wakeupManager = sharedApplicationContext.wakeupManager
                    sharedApplicationContext.wakeupManager.beginCleanupProcessingTask()
                    disposable.set(self.runCacheReindexTasks(lowImpact: true, optimizeDatabase: true, maintenanceExpired: expired, completion: {
                        Logger.shared.log("App \(self.episodeId)", "Completed cleanup task")
                        
                        finish(true)
                    }))
                })
            }
            
            BGTaskScheduler.shared.getPendingTaskRequests(completionHandler: { tasks in
                if tasks.contains(where: { $0.identifier == cleanupTaskId }) {
                    Logger.shared.log("App \(self.episodeId)", "Already have a cleanup task pending")
                    return
                }
                let request = BGProcessingTaskRequest(identifier: cleanupTaskId)
                request.requiresExternalPower = true
                request.requiresNetworkConnectivity = false
                
                do {
                    try BGTaskScheduler.shared.submit(request)
                } catch let e {
                    Logger.shared.log("App \(self.episodeId)", "Error submitting background task request: \(e)")
                }
            })
        }
        
        let timestamp = Int(CFAbsoluteTimeGetCurrent())
        let minReindexTimestamp = timestamp - 2 * 24 * 60 * 60
        if let indexTimestamp = UserDefaults.standard.object(forKey: "TelegramCacheIndexTimestamp_v2") as? NSNumber, indexTimestamp.intValue >= minReindexTimestamp {
        } else {
            UserDefaults.standard.set(timestamp as NSNumber, forKey: "TelegramCacheIndexTimestamp_v2")
            
            Logger.shared.log("App \(self.episodeId)", "Executing low-impact cache reindex in foreground")
            let _ = self.runCacheReindexTasks(lowImpact: true, completion: {
                Logger.shared.log("App \(self.episodeId)", "Executing low-impact cache reindex in foreground — done")
            })
        }
        
        if #available(iOS 12.0, *) {
            UIApplication.shared.registerForRemoteNotifications()
        }
        
        let _ = self.urlSession(identifier: "\(baseAppBundleId).backroundSession")
        
        var previousReportedMemoryConsumption = 0
        // Every 5 s (was 0.5 s, for the life of the app, background included). The value is only
        // logged on a >1 MB change and shown by a debug overlay; 2 Hz kept the main thread waking.
        let memoryReportTimer = Foundation.Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true, block: { _ in
            let value = getMemoryConsumption()
            if abs(value - previousReportedMemoryConsumption) > 1 * 1024 * 1024 {
                previousReportedMemoryConsumption = value
                Logger.shared.log("App \(self.episodeId)", "Memory consumption: \(value / (1024 * 1024)) MB")
                
                if self.contextValue?.context.sharedContext.immediateExperimentalUISettings.crashOnMemoryPressure == true {
                    let memoryUsageOverlayView: UILabel
                    if let current = self.memoryUsageOverlayView {
                        memoryUsageOverlayView = current
                    } else {
                        memoryUsageOverlayView = UILabel()
                        if #available(iOS 13.0, *) {
                            memoryUsageOverlayView.textColor = .label
                        } else {
                            memoryUsageOverlayView.textColor = .black
                        }
                        memoryUsageOverlayView.font = Font.regular(11.0)
                        memoryUsageOverlayView.layer.zPosition = 1000.0
                        self.memoryUsageOverlayView = memoryUsageOverlayView
                        self.window?.addSubview(memoryUsageOverlayView)
                        
                        memoryUsageOverlayView.center = CGPoint(x: 5.0, y: 36.0)
                    }
                    
                    memoryUsageOverlayView.text = "\(value / (1024 * 1024)) MB"
                    memoryUsageOverlayView.sizeToFit()
                } else {
                    if let memoryUsageOverlayView = self.memoryUsageOverlayView {
                        self.memoryUsageOverlayView = nil
                        memoryUsageOverlayView.removeFromSuperview()
                    }
                }
            }
        })
        memoryReportTimer.tolerance = 1.0
        
        //self.addBackgroundDownloadTask()
        
        let reflectorBenchmarkDisposable = MetaDisposable()
        let runReflectorBenchmarkDisposable = MetaDisposable()
        let _ = (self.context.get()
        |> deliverOnMainQueue).startStandalone(next: { context in
            reflectorBenchmarkDisposable.set(nil)
            runReflectorBenchmarkDisposable.set(nil)
            
            guard let context = context?.context else {
                return
            }
            var defaultAutoBenchmarkReflectors = false
            if case .internal = context.sharedContext.applicationBindings.appBuildType {
                defaultAutoBenchmarkReflectors = true
            }
            if context.sharedContext.immediateExperimentalUISettings.autoBenchmarkReflectors ?? defaultAutoBenchmarkReflectors {
                reflectorBenchmarkDisposable.set((context.sharedContext.applicationBindings.applicationInForeground
                |> distinctUntilChanged
                |> deliverOnMainQueue).startStrict(next: { value in
                    if value {
                        let signal: Signal<ReflectorBenchmark.Results, NoError> = Signal { subscriber in
                            var reflectorBenchmark: ReflectorBenchmark? = ReflectorBenchmark(address: "91.108.13.35", port: 599)
                            reflectorBenchmark?.start(completion: { results in
                                subscriber.putNext(results)
                                subscriber.putCompletion()
                            })
                            
                            return ActionDisposable {
                                reflectorBenchmark = nil
                            }
                        }
                        |> runOn(.mainQueue())
                        |> delay(Double.random(in: 1.0 ..< 5.0), queue: Queue.mainQueue())
                        runReflectorBenchmarkDisposable.set(signal.startStrict(next: { results in
                            print("Reflector banchmark:\nBandwidth: \(results.bandwidthBytesPerSecond * 8 / 1024) kbit/s (expected \(results.expectedBandwidthBytesPerSecond * 8 / 1024) kbit/s)\nAvg latency: \(Int(results.averageDelay * 1000.0)) ms")
                        }))
                    } else {
                        runReflectorBenchmarkDisposable.set(nil)
                    }
                }))
            }
        })
                
        return true
    }
    
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
        // Only the application-role scene owns the app's window and drives app-wide life-cycle
        // state. Other roles (e.g. an external display) get no delegate at all, so they cannot
        // take the account offline or dismiss overlays while the app is foreground on the phone.
        if connectingSceneSession.role == .windowApplication {
            configuration.delegateClass = SceneDelegate.self
        }
        return configuration
    }

    func attach(scene: UIWindowScene, connectionOptions: UIScene.ConnectionOptions) {
        self.statusBarHost?.scene = scene
        self.window?.windowScene = scene

        // UIKit registers a window's root view controller as that window's rotation client inside
        // -[UIWindow setRootViewController:], and only if the window already belongs to a scene. This
        // window is built in didFinishLaunching, before any scene exists, so the registration never
        // happened and the window never runs -[UIWindow _rotateWindowToOrientation:...]: it still
        // resizes on rotation, through the scene-geometry path, so the app itself looks correct, but
        // it never posts UIWindowWillRotateNotification / UIWindowDidRotateNotification.
        //
        // UIRemoteKeyboardWindow is a UIApplicationRotationFollowingWindow and rotates ONLY by
        // following those two notifications, so without this the keyboard keeps its launch
        // orientation and bounds: it stays pinned to the pre-rotation bottom edge, and the
        // keyboardWillChangeFrame the app then receives carries the stale portrait height.
        // Re-assign the controller now that the scene is bound. It must be a real value change --
        // re-assigning the same object early-returns in UIKit's setter and registers nothing.
        // (Measured on iOS 26.5; iOS 27 sources the keyboard geometry elsewhere and is unaffected,
        // so it cannot be used to verify this.)
        if let window = self.window, let rootViewController = window.rootViewController {
            window.rootViewController = nil
            window.rootViewController = rootViewController
        }

        self.mainWindow?.updateDeviceMetrics()
        self.window?.makeKeyAndVisible()

        // A link that launches the app goes where a link to the running app goes: openUrl waits for the
        // signed-in or the sign-in screen, so a tg://proxy, socks, webproxy or login-code link also works
        // on a device that is signed out (waiting for a signed-in account dropped those). The scene
        // lifecycle never puts the link in the launch options.
        for context in connectionOptions.urlContexts {
            self.handleOpenURL(context.url)
        }

        for userActivity in connectionOptions.userActivities {
            self.handleUserActivity(userActivity)
        }

        if let shortcutItem = connectionOptions.shortcutItem {
            self.handleShortcutItem(shortcutItem, completionHandler: { _ in })
        }
    }
    
    private var backgroundSessionSourceDataDisposables: [String: Disposable] = [:]
    private var backgroundUploadResultSubscribers: [String: Bag<(String?) -> Void>] = [:]
    
    func uploadInBackround(postbox: Postbox, resource: MediaResource) -> Signal<String?, NoError> {
        let baseAppBundleId = Bundle.main.bundleIdentifier!
        let session = self.urlSession(identifier: "\(baseAppBundleId).backroundSession")
        
        let signal = Signal<Never, NoError> { subscriber in
            let disposable = MetaDisposable()
            
            let _ = session.getAllTasks(completionHandler: { tasks in
                var alreadyExists = false
                for task in tasks {
                    if let originalRequest = task.originalRequest {
                        if let requestResourceId = originalRequest.value(forHTTPHeaderField: "tresource") {
                            if resource.id.stringRepresentation == requestResourceId {
                                alreadyExists = true
                                break
                            }
                        }
                    }
                }
                
                if !alreadyExists, self.backgroundSessionSourceDataDisposables[resource.id.stringRepresentation] == nil {
                    self.backgroundSessionSourceDataDisposables[resource.id.stringRepresentation] = (Signal<Never, NoError> { subscriber in
                        let dataDisposable = (postbox.mediaBox.resourceData(resource)
                        |> deliverOnMainQueue).start(next: { data in
                            if data.complete {
                                self.addBackgroundUploadTask(id: resource.id.stringRepresentation, path: data.path)
                            }
                        })
                        let fetchDisposable = postbox.mediaBox.fetchedResource(resource, parameters: nil).start()
                        
                        return ActionDisposable {
                            dataDisposable.dispose()
                            fetchDisposable.dispose()
                        }
                    }).start()
                }
            })
            
            return disposable
        }
        |> runOn(.mainQueue())
        
        return Signal { subscriber in
            let bag: Bag<(String?) -> Void>
            if let current = self.backgroundUploadResultSubscribers[resource.id.stringRepresentation] {
                bag = current
            } else {
                bag = Bag()
                self.backgroundUploadResultSubscribers[resource.id.stringRepresentation] = bag
            }
            let index = bag.add { result in
                subscriber.putNext(result)
                subscriber.putCompletion()
            }
            
            let workDisposable = signal.start()
            
            return ActionDisposable {
                workDisposable.dispose()
                
                Queue.mainQueue().async {
                    if let bag = self.backgroundUploadResultSubscribers[resource.id.stringRepresentation] {
                        bag.remove(index)
                        if bag.isEmpty {
                            //TODO:cancel tasks
                        }
                    }
                }
            }
        }
        |> runOn(.mainQueue())
    }
    
    private func addBackgroundUploadTask(id: String, path: String) {
        let baseAppBundleId = Bundle.main.bundleIdentifier!
        let session = self.urlSession(identifier: "\(baseAppBundleId).backroundSession")
        
        let fileName = "upload-\(UInt32.random(in: 0 ... UInt32.max))"
        let uploadFilePath = NSTemporaryDirectory() + "/" + fileName
        guard let sourceFile = ManagedFile(queue: nil, path: uploadFilePath, mode: .readwrite) else {
            return
        }
        guard let inFile = ManagedFile(queue: nil, path: path, mode: .read) else {
            return
        }
        
        let boundary = UUID().uuidString
        
        var headerData = Data()
        headerData.append("\r\n--\(boundary)\r\n".data(using: .utf8)!)
        headerData.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        headerData.append("Content-Type: image/png\r\n\r\n".data(using: .utf8)!)
        
        var footerData = Data()
        footerData.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        
        let _ = sourceFile.write(headerData)
        
        let bufferSize = 512 * 1024
        let buffer = malloc(bufferSize)!
        defer {
            free(buffer)
        }
        
        while true {
            let readBytes = inFile.read(buffer, bufferSize)
            if readBytes <= 0 {
                break
            } else {
                let _ = sourceFile.write(buffer, count: readBytes)
            }
        }
        
        let _ = sourceFile.write(footerData)
        
        sourceFile._unsafeClose()
        inFile._unsafeClose()
        
        var request = URLRequest(url: URL(string: "http://localhost:25478/upload?token=f9403fc5f537b4ab332d")!)
        request.httpMethod = "POST"
        
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(id, forHTTPHeaderField: "tresource")
        
        let task = session.uploadTask(with: request, fromFile: URL(fileURLWithPath: uploadFilePath))
        task.resume()
    }
    
    private func addBackgroundDownloadTask() {
        let baseAppBundleId = Bundle.main.bundleIdentifier!
        let session = self.urlSession(identifier: "\(baseAppBundleId).backroundSession")

        var request = URLRequest(url: URL(string: "https://example.com/\(UInt64.random(in: 0 ... UInt64.max))")!)
        request.httpMethod = "GET"
        
        let task = session.downloadTask(with: request)
        Logger.shared.log("App \(self.episodeId)", "adding download task \(String(describing: request.url))")
        task.earliestBeginDate = Date(timeIntervalSinceNow: 30.0)
        task.resume()
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        Logger.shared.log("App \(self.episodeId)", "completed download task \(String(describing: task.originalRequest?.url)) error: \(String(describing: error))")
        if let response = task.response as? HTTPURLResponse {
            if let originalRequest = task.originalRequest {
                if let requestResourceId = originalRequest.value(forHTTPHeaderField: "tresource") {
                    if let bag = self.backgroundUploadResultSubscribers[requestResourceId] {
                        for item in bag.copyItems() {
                            item("http server: \(response.allHeaderFields)")
                        }
                    }
                }
            }
        }
    }
    
    /// `optimizeDatabase`: also VACUUM each account's database when it is fragmented (see
    /// `Postbox.optimizeStorageIfNeeded`). Only the background processing task passes true: VACUUM
    /// blocks the account's database queue while it rewrites the file.
    private func runCacheReindexTasks(lowImpact: Bool, optimizeDatabase: Bool = false, maintenanceExpired: Atomic<Bool>? = nil, completion: @escaping () -> Void) -> Disposable {
        let disposable = MetaDisposable()
        let isActive = self.maintenanceIsActive
        let isInForeground = self.maintenanceIsInForeground
        
        let _ = (self.sharedContextPromise.get()
        |> take(1)
        |> deliverOnMainQueue).start(next: { sharedApplicationContext in
            let _ = (sharedApplicationContext.sharedContext.activeAccountContexts
            |> take(1)
            |> deliverOnMainQueue).start(next: { activeAccounts in
                var signals: Signal<Never, NoError> = .complete()
                
                for (_, context, _) in activeAccounts.accounts {
                    signals = signals |> then(context.account.cleanupTasks(lowImpact: lowImpact))
                    if optimizeDatabase {
                        let postbox = context.account.postbox
                        signals = signals |> then(Signal<Never, NoError>.complete() |> deliverOnMainQueue |> then(Signal<Never, NoError> { subscriber in
                            // Never while the app is on screen.
                            if UIApplication.shared.applicationState == .active {
                                Logger.shared.log("App", "Skipping database optimization: app is active")
                                subscriber.putCompletion()
                                return EmptyDisposable
                            }
                            // Right before the VACUUM (on the Postbox queue): not when the time is up or the user is back.
                            // Databases with more than 256 MB of live data are left alone: they take too long to rewrite.
                            return (postbox.optimizeStorageIfNeeded(maxLiveBytes: 256 * 1024 * 1024, shouldProceed: {
                                if let maintenanceExpired, maintenanceExpired.with({ $0 }) {
                                    return false
                                }
                                return !isActive.with({ $0 }) && !isInForeground.with({ $0 })
                            })
                            |> ignoreValues).start(completed: {
                                subscriber.putCompletion()
                            })
                        }))
                    }
                }
                
                disposable.set(signals.start(completed: {
                    completion()
                }))
            })
        })
        
        return disposable
    }

    /// Stops a VACUUM that is running on any account database, so no file lock is held when the app is suspended
    /// (background time is up) or when the user is back.
    private func interruptDatabaseMaintenance() {
        let _ = (self.sharedContextPromise.get()
        |> take(1)
        |> deliverOnMainQueue).start(next: { sharedApplicationContext in
            let _ = (sharedApplicationContext.sharedContext.activeAccountContexts
            |> take(1)
            |> deliverOnMainQueue).start(next: { activeAccounts in
                for (_, context, _) in activeAccounts.accounts {
                    context.account.postbox.interruptMaintenance()
                }
            })
        })
    }

    private func resetBadge() {
        var resetOnce = true
        self.badgeDisposable.set((self.context.get()
        |> mapToSignal { context -> Signal<Int32, NoError> in
            if let context = context {
                return context.applicationBadge
            } else {
                return .single(0)
            }
        }
        |> deliverOnMainQueue).start(next: { count in
            if resetOnce {
                resetOnce = false
                if count == 0 {
                    //UIApplication.shared.applicationIconBadgeNumber = 1
                }
            }
            if #available(iOS 16.0, *) {
                UNUserNotificationCenter.current().setBadgeCount(Int(count), withCompletionHandler: nil)
            } else {
                UIApplication.shared.applicationIconBadgeNumber = Int(count)
            }
        }))
    }

    func handleWillResignActive() {
        self.isActiveValue = false
        self.isActivePromise.set(false)
        self.clearNotificationsManager?.commitNow()
        
        if let navigationController = self.mainWindow.viewController as? NavigationController {
            for controller in navigationController.viewControllers {
                if let controller = controller as? TabBarController {
                    for subController in controller.controllers {
                        subController.forEachController { controller in
                            if let controller = controller as? UndoOverlayController {
                                controller.dismissWithCommitAction()
                            }
                            return true
                        }
                    }
                }
            }
        }
        self.mainWindow.forEachViewController({ controller in
            if let controller = controller as? UndoOverlayController {
                controller.dismissWithCommitAction()
            }
            return true
        })
    }

    // iOS asks for memory back before it kills the app. Drop the same Postbox caches as on
    // entering the background (proven safe: live views keep their own copies) and stale
    // request-throttle records. Nothing visible is affected.
    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        Logger.shared.log("App \(self.episodeId)", "Memory warning")
        let _ = (self.sharedContextPromise.get()
        |> take(1)
        |> mapToSignal { sharedApplicationContext in
            return sharedApplicationContext.sharedContext.activeAccountContexts |> take(1)
        }
        |> deliverOnMainQueue).start(next: { activeAccounts in
            for (_, context, _) in activeAccounts.accounts {
                context.account.postbox.clearCaches()
                context.account.viewTracker.pruneThrottleState()
            }
        })
    }
    
    func handleDidEnterBackground() {
        Logger.shared.flushPendingShortLog()
        let _ = (self.sharedContextPromise.get()
        |> take(1)
        |> deliverOnMainQueue).start(next: { sharedApplicationContext in
            var extendNow = false
            if #available(iOS 9.0, *) {
                if !ProcessInfo.processInfo.isLowPowerModeEnabled {
                    extendNow = true
                }
            }
            if !sharedApplicationContext.sharedContext.energyUsageSettings.extendBackgroundWork {
                extendNow = false
            }
            sharedApplicationContext.wakeupManager.allowBackgroundTimeExtension(timeout: 2.0, extendNow: extendNow)
            
            let _ = (sharedApplicationContext.sharedContext.activeAccountContexts
             |> take(1)
             |> deliverOnMainQueue).start(next: { activeAccounts in
                for (_, context, _) in activeAccounts.accounts {
                    context.account.postbox.clearCaches()
                    context.account.viewTracker.pruneThrottleState()
                }
            })
        })
        
        self.isInForegroundValue = false
        self.isInForegroundPromise.set(false)
        self.isActiveValue = false
        self.isActivePromise.set(false)
        
        self.reportDiskWrites(reason: "background")
        
        // Ended once, by its 5 s deadline or the system's expiration, whichever comes first.
        let lockTask = OneShotBackgroundTask<UIBackgroundTaskIdentifier>(end: { taskId in
            UIApplication.shared.endBackgroundTask(taskId)
        })
        lockTask.begin { expiration in
            let taskId = UIApplication.shared.beginBackgroundTask(withName: "lock", expirationHandler: {
                MainActor.assumeIsolated {
                    expiration()
                }
            })
            return taskId == .invalid ? nil : taskId
        }
        self.lockBackgroundTask = lockTask
        DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 5.0, execute: { [weak self] in
            guard let self else {
                lockTask.end()
                return
            }
            // Through the wakeup manager, which pauses database writes (and waits for the running
            // transaction) before the task ends, unless something else keeps the app awake (0xdead10cc).
            let _ = (self.sharedContextPromise.get()
            |> take(1)
            |> deliverOnMainQueue).start(next: { sharedApplicationContext in
                sharedApplicationContext.wakeupManager.releaseBackgroundTime {
                    MainActor.assumeIsolated {
                        lockTask.end()
                    }
                }
            })
        })
        
        self.backgroundDiagnostics.didEnterBackground(isEnabled: Logger.shared.logToFile, report: { [weak self] secondsInBackground in
            self?.logBackgroundDiagnostics(secondsInBackground: secondsInBackground)
        })
    }
    
    /// Who wrote how much to disk (DiskWriteAccounting): one log line an hour while the app runs, one on entering the
    /// background and one on returning to the foreground, and the per-day totals in `logs/disk-writes.json`, which Send MetricKit Reports includes. The
    /// counters are always on; the log line reaches the file only with "Log to File" on.
    private func startDiskWriteReports(ledgerPath: String) {
        DiskWriteAccountingReporting.install(ledgerPath: ledgerPath)
        self.diskWriteReportTimer?.invalidate()
        let timer = Foundation.Timer(timeInterval: 60.0 * 60.0, repeats: true, block: { [weak self] _ in
            self?.reportDiskWrites(reason: "hourly")
        })
        timer.tolerance = 60.0
        RunLoop.main.add(timer, forMode: .common)
        self.diskWriteReportTimer = timer
    }
    
    private func reportDiskWrites(reason: String) {
        guard let reporter = DiskWriteAccountingReporting.current else {
            return
        }
        let episodeId = self.episodeId
        DispatchQueue.global(qos: .utility).async {
            // Outside the log call: its message is only evaluated with "Log to File" on, and the ledger must be
            // updated either way.
            let line = reporter.report(reason: reason)
            Logger.shared.log("App \(episodeId)", line)
        }
    }
    
    /// One log line about what the app still holds after entering the background (see BackgroundDiagnostics). Only
    /// with "Log to File" on; nothing leaves the device.
    private func logBackgroundDiagnostics(secondsInBackground: Double) {
        let memory = ProcessMemory.current()
        let backgroundTimeRemaining = UIApplication.shared.backgroundTimeRemaining
        let lockTaskActive = self.lockBackgroundTask?.isActive == true
        let displayLinks = SharedDisplayLinkDriver.shared.diagnosticCounts
        let _ = (combineLatest(queue: .mainQueue(), self.sharedContextPromise.get() |> take(1), self.hasActiveAudioSession.get() |> take(1))
        |> deliverOnMainQueue).start(next: { sharedApplicationContext, hasActiveAudioSession in
            var backgroundTasks = sharedApplicationContext.wakeupManager.diagnosticHeldTasks
            if lockTaskActive {
                backgroundTasks.insert("lock", at: 0)
            }
            let themeImages = sharedApplicationContext.sharedContext.currentPresentationData.with({ $0 }).theme.resourceCache.diagnosticImageBytes
            let report = BackgroundDiagnosticsReport(
                secondsInBackground: secondsInBackground,
                memory: memory,
                backgroundTimeRemaining: backgroundTimeRemaining,
                backgroundTasks: backgroundTasks,
                audioSessionActive: hasActiveAudioSession,
                displayLinks: BackgroundDiagnosticsReport.DisplayLinkCounts(registered: displayLinks.registered, running: displayLinks.running, driverRunning: displayLinks.driverRunning),
                caches: [
                    BackgroundDiagnosticsReport.CacheSize(name: "theme images", bytes: themeImages)
                ]
            )
            Logger.shared.log("App \(self.episodeId)", report.logLine)
        })
    }

    func handleWillEnterForeground() {
        self.interruptDatabaseMaintenance()
        self.backgroundDiagnostics.willEnterForeground()
        // What was written while in the background (background sync, downloads, pushes).
        self.reportDiskWrites(reason: "foreground")
        if self.isActiveValue {
            self.isInForegroundValue = true
            self.isInForegroundPromise.set(true)
        } else {
            if #available(iOSApplicationExtension 12.0, *) {
                DispatchQueue.main.async {
                    self.isInForegroundValue = true
                    self.isInForegroundPromise.set(true)
                }
            }
        }
        
        self.runForegroundTasks()
        
        SharedDisplayLinkDriver.shared.updateForegroundState(self.isActiveValue)
    }
    
    func runForegroundTasks() {
        let _ = (self.sharedContextPromise.get()
        |> take(1)
        |> deliverOnMainQueue).start(next: { sharedApplicationContext in
            let _ = (sharedApplicationContext.sharedContext.activeAccountContexts
             |> take(1)
             |> deliverOnMainQueue).start(next: { activeAccounts in
                for (_, context, _) in activeAccounts.accounts {
                    (context.downloadedMediaStoreManager as? DownloadedMediaStoreManagerImpl)?.runTasks()
                }
            })
        })
    }

    func handleDidBecomeActive() {
        self.isInForegroundValue = true
        self.isInForegroundPromise.set(true)
        self.isActiveValue = true
        self.isActivePromise.set(true)

        self.resetBadge()

        UNUserNotificationCenter.current().getDeliveredNotifications(completionHandler: { [weak self] notifications in
            self?.removeStaleServicePushNotifications(notifications)
        })
        
        SharedDisplayLinkDriver.shared.updateForegroundState(self.isActiveValue)
        
        func cancelWindowPanGestures(view: UIView) {
            if let gestureRecognizers = view.gestureRecognizers {
                for recognizer in gestureRecognizers {
                    if let recognizer = recognizer as? WindowPanRecognizer {
                        recognizer.cancel()
                    }
                }
            }
            
            for subview in view.subviews {
                cancelWindowPanGestures(view: subview)
            }
        }
        
        //cancelWindowPanGestures(view: self.mainWindow.hostView.containerView)
    }
    
    /// Service pushes the notification service extension could not take down (see
    /// `ServicePushNotifications`): its quiet placeholders, and, once the app is active and shows
    /// the chats, the server's own alerts. Neither carries a message id the read-state clearing
    /// could match.
    private func removeStaleServicePushNotifications(_ notifications: [UNNotification]) {
        let delivered = notifications.map { notification -> (identifier: String, userInfo: [AnyHashable: Any]) in
            return (notification.request.identifier, notification.request.content.userInfo)
        }
        let datedDelivered = notifications.map { notification -> (identifier: String, userInfo: [AnyHashable: Any], date: Date) in
            return (notification.request.identifier, notification.request.content.userInfo, notification.date)
        }
        Queue.mainQueue().async { [weak self] in
            guard let self else {
                return
            }
            var identifiers = ServicePushNotifications.staleIdentifiers(delivered: delivered, includeServerFallbacks: self.isActiveValue)
            identifiers.append(contentsOf: IncomingCallNotifications.staleIdentifiers(delivered: datedDelivered, now: Date()))
            if !identifiers.isEmpty {
                Logger.shared.log("App \(self.episodeId)", "Removing \(identifiers.count) service push and stale call notifications")
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
            }
        }
    }

    func applicationWillTerminate(_ application: UIApplication) {
        Logger.shared.log("App \(self.episodeId)", "terminating")
        Logger.shared.flushPendingShortLog()
    }
    
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Logger.shared.log("App \(self.episodeId)", "register for notifications: didRegisterForRemoteNotificationsWithDeviceToken (deviceToken: \(hexString(deviceToken)))")
        self.notificationTokenPromise.set(.single(deviceToken))
    }
    
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Logger.shared.log("App \(self.episodeId)", "register for notifications: didFailToRegisterForRemoteNotificationsWithError (error: \(error))")
    }
    
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable : Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        let _ = (self.sharedContextPromise.get()
        |> take(1)
        |> deliverOnMainQueue).start(next: { sharedApplicationContext in
            sharedApplicationContext.wakeupManager.allowBackgroundTimeExtension(timeout: 2.0)
        })
        
        var redactedPayload = userInfo
        if var aps = redactedPayload["aps"] as? [AnyHashable: Any] {
            if Logger.shared.redactSensitiveData {
                if aps["alert"] != nil {
                    aps["alert"] = "[[redacted]]"
                }
                if aps["body"] != nil {
                    aps["body"] = "[[redacted]]"
                }
            }
            redactedPayload["aps"] = aps
        }
        
        Logger.shared.log("App \(self.episodeId)", "remoteNotification: \(redactedPayload)")
        
        if let firebaseAuth = redactedPayload["com.google.firebase.auth"] as? String {
            guard let firebaseAuthData = firebaseAuth.data(using: .utf8), let firebaseJson = try? JSONSerialization.jsonObject(with: firebaseAuthData) else {
                completionHandler(.newData)
                return
            }
            guard let firebaseDict = firebaseJson as? [String: Any] else {
                completionHandler(.newData)
                return
            }
            
            if let receipt = firebaseDict["receipt"] as? String, let secret = firebaseDict["secret"] as? String {
                var firebaseSecrets = self.firebaseSecrets
                firebaseSecrets[receipt] = secret
                self.firebaseSecrets = firebaseSecrets
            }
            
            completionHandler(.newData)
            return
        }
        
        if let nonce = redactedPayload["verify_nonce"] as? String, let secret = redactedPayload["verify_secret"] as? String {
            var firebaseRequestVerificationSecrets = self.firebaseRequestVerificationSecrets
            firebaseRequestVerificationSecrets[nonce] = secret
            self.firebaseRequestVerificationSecrets = firebaseRequestVerificationSecrets
            
            completionHandler(.newData)
            return
        }

        if userInfo["p"] == nil {
            completionHandler(.noData)
            return
        }
        
        let _ = (self.sharedContextPromise.get()
        |> take(1)
        |> deliverOnMainQueue).start(next: { sharedApplicationContext in
            sharedApplicationContext.wakeupManager.replaceCurrentExtensionWithExternalTime(completion: {
                completionHandler(.newData)
            }, timeout: 29.0)
            sharedApplicationContext.notificationManager.addNotification(userInfo)
        })
    }

    public func pushRegistry(_ registry: PKPushRegistry, didUpdate credentials: PKPushCredentials, for type: PKPushType) {
        if #available(iOS 9.0, *) {
            if case PKPushType.voIP = type {
                Logger.shared.log("App \(self.episodeId)", "pushRegistry credentials: \(credentials.token as NSData)")
                
                self.voipTokenPromise.set(.single(credentials.token))
            }
        }
    }
    
    public func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
        Logger.shared.log("App \(self.episodeId) PushRegistry", "pushRegistry didReceiveIncomingPushWith \(payload.dictionaryPayload)")
        
        self.pushRegistryImpl(registry, didReceiveIncomingPushWith: payload, for: type, completion: completion)
    }
    
    public func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType) {
        Logger.shared.log("App \(self.episodeId) PushRegistry", "pushRegistry didReceiveIncomingPushWith \(payload.dictionaryPayload)")
        
        self.pushRegistryImpl(registry, didReceiveIncomingPushWith: payload, for: type, completion: {})
    }
    
    private func pushRegistryImpl(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
        Logger.shared.log("App \(self.episodeId) PushRegistry", "pushRegistry processing push notification")

        // Every way out reports a call to CallKit (a placeholder ended at once if this push carries
        // none we can use): iOS stops delivering VoIP pushes to an app that skips that.
        let callReport = VoIPPushCallReport(reportFailedCall: { [self] in
            if case PKPushType.voIP = type {
                self.reportFailedIncomingCallKitCall()
            }
        }, completion: completion)
        
        let decryptedPayloadAndAccountId: ([AnyHashable: Any], AccountRecordId)?
        
        if let accountIdString = payload.dictionaryPayload["accountId"] as? String, let accountId = Int64(accountIdString) {
            decryptedPayloadAndAccountId = (payload.dictionaryPayload, AccountRecordId(rawValue: accountId))
        } else {
            guard var encryptedPayload = payload.dictionaryPayload["p"] as? String else {
                Logger.shared.log("App \(self.episodeId) PushRegistry", "encryptedPayload is nil")
                callReport.complete()
                return
            }
            encryptedPayload = encryptedPayload.replacingOccurrences(of: "-", with: "+")
            encryptedPayload = encryptedPayload.replacingOccurrences(of: "_", with: "/")
            while encryptedPayload.count % 4 != 0 {
                encryptedPayload.append("=")
            }
            guard let payloadData = Data(base64Encoded: encryptedPayload) else {
                Logger.shared.log("App \(self.episodeId) PushRegistry", "Couldn't decode encryptedPayload")
                callReport.complete()
                return
            }
            guard let keyId = notificationPayloadKeyId(data: payloadData) else {
                Logger.shared.log("App \(self.episodeId) PushRegistry", "Couldn't parse payload key id")
                callReport.complete()
                return
            }
            guard let accountManagerState = self.accountManagerState else {
                Logger.shared.log("App \(self.episodeId) PushRegistry", "accountManagerState is nil")
                callReport.complete()
                return
            }

            var maybeAccountId: AccountRecordId?
            var maybeNotificationKey: MasterNotificationKey?

            for key in accountManagerState.notificationKeys {
                if key.id == keyId {
                    maybeAccountId = key.accountId
                    maybeNotificationKey = MasterNotificationKey(id: key.id, data: key.key)
                    break
                }
            }

            guard let accountId = maybeAccountId, let notificationKey = maybeNotificationKey else {
                Logger.shared.log("App \(self.episodeId) PushRegistry", "accountId or notificationKey is nil")
                callReport.complete()
                return
            }
            guard let decryptedPayload = decryptedNotificationPayload(key: notificationKey, data: payloadData) else {
                Logger.shared.log("App \(self.episodeId) PushRegistry", "Couldn't decrypt payload")
                callReport.complete()
                return
            }
            guard let payloadJson = try? JSONSerialization.jsonObject(with: decryptedPayload, options: []) as? [AnyHashable: Any] else {
                Logger.shared.log("App \(self.episodeId) PushRegistry", "Couldn't decode payload json")
                callReport.complete()
                return
            }
            
            decryptedPayloadAndAccountId = (payloadJson, accountId)
        }
        
        guard let (payloadJson, accountId) = decryptedPayloadAndAccountId else {
            Logger.shared.log("App \(self.episodeId) PushRegistry", "decryptedPayloadAndAccountId is nil")
            callReport.complete()
            return
        }
        
        let phoneNumber = payloadJson["phoneNumber"] as? String
        
        if let fromIdString = payloadJson["from_id"] as? String, let fromId = Int64(fromIdString), let groupCallIdString = payloadJson["group_call_id"] as? String, let groupCallId = Int64(groupCallIdString), let messageIdString = payloadJson["msg_id"] as? String, let messageId = Int32(messageIdString), let fromTitle = payloadJson["from_title"] as? String {
            guard let callKitIntegration = CallKitIntegration.shared else {
                Logger.shared.log("App \(self.episodeId) PushRegistry", "CallKitIntegration is not available")
                callReport.complete()
                return
            }
            
            var isVideo = false
            if let isVideoString = payloadJson["video"] as? String, let isVideoValue = Int32(isVideoString) {
                isVideo = isVideoValue != 0
            } else if let isVideoString = payloadJson["video"] as? String, let isVideoValue = Bool(isVideoString) {
                isVideo = isVideoValue
            }

            let fromPeerId = PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value(fromId))
            let messageId = MessageId(peerId: fromPeerId, namespace: Namespaces.Message.Cloud, id: messageId)
            
            let internalId = CallSessionManager.getStableIncomingUUID(peerId: fromPeerId.id._internalGetInt64Value(), messageId: messageId.id)
            
            var strings: PresentationStrings = defaultPresentationStrings
            let _ = (self.sharedContextPromise.get()
            |> take(1)
            |> deliverOnMainQueue).start(next: { sharedApplicationContext in
                strings = sharedApplicationContext.sharedContext.currentPresentationData.with { $0.strings }
            })

            let displayTitle: String
            if let memberCountString = payloadJson["member_count"] as? String, let memberCount = Int(memberCountString) {
                displayTitle = strings.Call_IncomingGroupCallTitle_Multiple(Int32(memberCount)).replacingOccurrences(of: "{}", with: fromTitle)
            } else {
                displayTitle = strings.Call_IncomingGroupCallTitle_Single(fromTitle).string
            }
            
            callReport.callReported()
            callKitIntegration.reportIncomingCall(
                uuid: internalId,
                stableId: groupCallId,
                handle: CallKitHandle.value(accountId: accountId, peerId: fromPeerId),
                phoneNumber: phoneNumber.flatMap(formatPhoneNumber),
                isVideo: isVideo,
                displayTitle: displayTitle,
                completion: { error in
                    if error == nil {
                        // CallKit rings it now: the extension's ringing notification must not ring too.
                        removeDeliveredIncomingCallNotifications(peerId: fromPeerId)
                    }
                    if let error = error {
                        if error.domain == "com.apple.CallKit.error.incomingcall" && (error.code == -3 || error.code == 3) {
                            Logger.shared.log("PresentationCall", "reportIncomingCall device in DND mode")
                        } else {
                            Logger.shared.log("PresentationCall", "reportIncomingCall error \(error)")
                            /*Queue.mainQueue().async {
                             if let strongSelf = self {
                             strongSelf.callSessionManager.drop(internalId: strongSelf.internalId, reason: .hangUp, debugLog: .single(nil))
                             }
                             }*/
                        }
                    }
                }
            )
            
            let _ = (self.sharedContextPromise.get()
            |> take(1)
            |> deliverOnMainQueue).start(next: { sharedApplicationContext in
                let _ = (sharedApplicationContext.sharedContext.activeAccountContexts
                |> take(1)
                |> deliverOnMainQueue).start(next: { activeAccounts in
                    var processed = false
                    for (_, context, _) in activeAccounts.accounts {
                        if context.account.id == accountId {
                            context.account.callSessionManager.addConferenceInvitationMessages(ids: [(messageId, IncomingConferenceTermporaryExternalInfo(callId: groupCallId, isVideo: isVideo))])
                            
                            let disposable = MetaDisposable()
                            self.watchedCallsDisposables.add(disposable)
                            
                            if let callManager = context.sharedContext.callManager {
                                let signal = combineLatest(queue: .mainQueue(), context.account.callSessionManager.ringingStates()
                                    |> map { ringingStates -> Bool in
                                        for state in ringingStates {
                                            if state.id == internalId {
                                                return true
                                            }
                                        }
                                        return false
                                    },
                                    callManager.currentGroupCallSignal
                                    |> map { currentGroupCall -> Bool in
                                        if case let .group(groupCall) = currentGroupCall {
                                            if groupCall.internalId == internalId {
                                                return true
                                            }
                                        }
                                        return false
                                    }
                                )
                                |> mapToSignal { exists0, exists1 -> Signal<Void, NoError> in
                                    if !(exists0 || exists1) {
                                        return .single(Void())
                                        |> delay(1.0, queue: .mainQueue())
                                    }
                                    return .never()
                                }
                                
                                disposable.set((signal
                                |> take(1)
                                |> deliverOnMainQueue).startStrict(next: { _ in
                                    callKitIntegration.dropCall(uuid: internalId)
                                }))
                            }
                            
                            processed = true
                            
                            break
                        }
                    }
                    
                    if !processed {
                        callKitIntegration.dropCall(uuid: internalId)
                    }
                })
                
                sharedApplicationContext.wakeupManager.allowBackgroundTimeExtension(timeout: 2.0)
                
                if case PKPushType.voIP = type {
                    Logger.shared.log("App \(self.episodeId) PushRegistry", "pushRegistry payload: \(payload.dictionaryPayload)")
                    sharedApplicationContext.notificationManager.addNotification(payload.dictionaryPayload)
                }
            })
        } else {
            guard var updateString = payloadJson["updates"] as? String else {
                Logger.shared.log("App \(self.episodeId) PushRegistry", "updates is nil")
                callReport.complete()
                return
            }
            
            updateString = updateString.replacingOccurrences(of: "-", with: "+")
            updateString = updateString.replacingOccurrences(of: "_", with: "/")
            while updateString.count % 4 != 0 {
                updateString.append("=")
            }
            guard let updateData = Data(base64Encoded: updateString) else {
                Logger.shared.log("App \(self.episodeId) PushRegistry", "Couldn't decode updateData")
                callReport.complete()
                return
            }
            guard let callUpdate = AccountStateManager.extractIncomingCallUpdate(data: updateData) else {
                Logger.shared.log("App \(self.episodeId) PushRegistry", "Couldn't extract call update")
                callReport.complete()
                return
            }
            guard let callKitIntegration = CallKitIntegration.shared else {
                Logger.shared.log("App \(self.episodeId) PushRegistry", "CallKitIntegration is not available")
                callReport.complete()
                return
            }
            
            callReport.callReported()
            callKitIntegration.reportIncomingCall(
                uuid: CallSessionManager.getStableIncomingUUID(stableId: callUpdate.callId),
                stableId: callUpdate.callId,
                handle: CallKitHandle.value(accountId: accountId, peerId: callUpdate.peer.id),
                phoneNumber: phoneNumber.flatMap(formatPhoneNumber),
                isVideo: callUpdate.isVideo,
                displayTitle: callUpdate.peer.debugDisplayTitle,
                completion: { error in
                    if error == nil {
                        // CallKit rings it now: the extension's ringing notification must not ring too.
                        removeDeliveredIncomingCallNotifications(peerId: callUpdate.peer.id)
                    }
                    if let error = error {
                        if error.domain == "com.apple.CallKit.error.incomingcall" && (error.code == -3 || error.code == 3) {
                            Logger.shared.log("PresentationCall", "reportIncomingCall device in DND mode")
                        } else {
                            Logger.shared.log("PresentationCall", "reportIncomingCall error \(error)")
                            /*Queue.mainQueue().async {
                             if let strongSelf = self {
                             strongSelf.callSessionManager.drop(internalId: strongSelf.internalId, reason: .hangUp, debugLog: .single(nil))
                             }
                             }*/
                        }
                    }
                }
            )
            
            let _ = (self.sharedContextPromise.get()
            |> take(1)
            |> deliverOnMainQueue).start(next: { sharedApplicationContext in
                let _ = (sharedApplicationContext.sharedContext.activeAccountContexts
                |> take(1)
                |> deliverOnMainQueue).start(next: { activeAccounts in
                    var processed = false
                    for (_, context, _) in activeAccounts.accounts {
                        if context.account.id == accountId {
                            context.account.stateManager.processIncomingCallUpdate(data: updateData, completion: { _ in
                            })
                            
                            let disposable = MetaDisposable()
                            self.watchedCallsDisposables.add(disposable)
                            
                            disposable.set((context.account.callSessionManager.callState(internalId: CallSessionManager.getStableIncomingUUID(stableId: callUpdate.callId))
                            |> deliverOnMainQueue).start(next: { state in
                                switch state.state {
                                case .terminated:
                                    callKitIntegration.dropCall(uuid: CallSessionManager.getStableIncomingUUID(stableId: callUpdate.callId))
                                default:
                                    break
                                }
                            }))
                            
                            processed = true
                            
                            break
                        }
                    }
                    
                    if !processed {
                        callKitIntegration.dropCall(uuid: CallSessionManager.getStableIncomingUUID(stableId: callUpdate.callId))
                    }
                })
                
                sharedApplicationContext.wakeupManager.allowBackgroundTimeExtension(timeout: 2.0)
                
                if case PKPushType.voIP = type {
                    Logger.shared.log("App \(self.episodeId) PushRegistry", "pushRegistry payload: \(payload.dictionaryPayload)")
                    sharedApplicationContext.notificationManager.addNotification(payload.dictionaryPayload)
                }
            })
        }
        
        Logger.shared.log("App \(self.episodeId) PushRegistry", "Invoking completion handler")
        
        callReport.complete()
    }
    
    public func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        Logger.shared.log("App \(self.episodeId)", "invalidated token for \(type)")
    }
    
    private func reportFailedIncomingCallKitCall() {
        if #available(iOS 14.4, *) {
            guard let callKitIntegration = CallKitIntegration.shared else {
                return
            }
            let uuid = CallSessionInternalId()
            callKitIntegration.reportIncomingCall(
                uuid: uuid,
                stableId: Int64.random(in: Int64.min ... Int64.max),
                handle: "Unknown",
                phoneNumber: nil,
                isVideo: false,
                displayTitle: "Unknown",
                completion: { error in
                    if let error = error {
                        if error.domain == "com.apple.CallKit.error.incomingcall" && (error.code == -3 || error.code == 3) {
                            Logger.shared.log("PresentationCall", "reportFailedIncomingCallKitCall device in DND mode")
                        } else {
                            Logger.shared.log("PresentationCall", "reportFailedIncomingCallKitCall error \(error)")
                        }
                    }
                }
            )
            Queue.mainQueue().after(1.0, {
                callKitIntegration.dropCall(uuid: uuid)
            })
        }
    }
    
    private func authorizedContext() -> Signal<AuthorizedApplicationContext, NoError> {
        return self.context.get()
        |> mapToSignal { context -> Signal<AuthorizedApplicationContext, NoError> in
            if let context = context {
                return .single(context)
            } else {
                return .complete()
            }
        }
    }
    
    func handleOpenURL(_ url: URL) {
        guard self.openUrlInProgress != url else {
            return
        }
        self.noteOpenUrlInProgress(url)
        self.openUrl(url: url)
    }
    
    /// The same link delivered twice within a second (a launch and a scene callback) opens once. Only for that
    /// second: a link still waiting for a signed-in account must not swallow the next tap on it.
    private func noteOpenUrlInProgress(_ url: URL) {
        self.openUrlInProgress = url
        Queue.mainQueue().after(1.0, { [weak self] in
            if let self, self.openUrlInProgress == url {
                self.openUrlInProgress = nil
            }
        })
    }

    private func presentWalletUnavailable(in context: AuthorizedApplicationContext) {
        let presentationData = context.context.sharedContext.currentPresentationData.with { $0 }
        context.context.sharedContext.presentGlobalController(UndoOverlayController(presentationData: presentationData, content: .info(title: nil, text: presentationData.strings.Wallet_Unavailable, timeout: nil, customUndoText: nil), action: { _ in return false }), nil)
    }

    private func openUrl(url: URL) {
        let _ = (self.sharedContextPromise.get()
        |> take(1)
        |> mapToSignal { sharedApplicationContext -> Signal<(SharedAccountContextImpl, AuthorizedApplicationContext?, UnauthorizedApplicationContext?), NoError> in
            combineLatest(self.context.get(), self.authContext.get())
            |> filter { $0 != nil || $1 != nil }
            |> take(1)
            |> map { context, authContext -> (SharedAccountContextImpl, AuthorizedApplicationContext?, UnauthorizedApplicationContext?) in
                return (sharedApplicationContext.sharedContext, context, authContext)
            }
        }
        |> deliverOnMainQueue).start(next: { sharedContext, context, authContext in
            if let authContext = authContext, let confirmationCode = parseConfirmationCodeUrl(sharedContext: sharedContext, url: url) {
                authContext.rootController.applyConfirmationCode(confirmationCode)
            } else if let context = context {
                if (WalletContext.isTonConnectUrl(url.absoluteString) || url.scheme?.lowercased() == "ton"), !WalletConfiguration.with(appConfiguration: context.context.currentAppConfiguration.with { $0 }).isAvailable {
                    self.presentWalletUnavailable(in: context)
                } else if WalletContext.isTonConnectUrl(url.absoluteString) {
                    context.context.walletContext?.processTonConnectUrl(url.absoluteString)
                } else if url.scheme?.lowercased() == "ton" {
                    if isTonTransferUrl(url), let walletContext = context.context.walletContext {
                        context.rootController.pushViewController(WalletSendScreen(
                            context: context.context,
                            walletContext: walletContext,
                            address: url.absoluteString
                        ))
                    }
                } else {
                    context.openUrl(url, external: true)
                }
            } else if let authContext = authContext {
                if let proxyData = parseProxyUrl(sharedContext: sharedContext, url: url) {
                    authContext.rootController.view.endEditing(true)
                    let presentationData = authContext.sharedContext.currentPresentationData.with { $0 }
                    let controller = ProxyServerPreviewScreen(sharedContext: authContext.sharedContext, network: authContext.account.network, updatedPresentationData: (presentationData, authContext.sharedContext.presentationData), server: proxyData)
                    authContext.rootController.currentWindow?.present(controller, on: PresentationSurfaceLevel.root, blockInteraction: false, completion: {})
                } else if let secureIdData = parseSecureIdUrl(url) {
                    let presentationData = authContext.sharedContext.currentPresentationData.with { $0 }
                    
                    let alertController = textAlertController(
                        sharedContext: authContext.sharedContext,
                        title: nil,
                        text: presentationData.strings.Passport_NotLoggedInMessage,
                        actions: [
                            TextAlertAction(type: .genericAction, title: presentationData.strings.Calls_NotNow, action: {
                                if let callbackUrl = URL(string: secureIdCallbackUrl(with: secureIdData.callbackUrl, peerId: secureIdData.peerId, result: .cancel, parameters: [:])) {
                                    UIApplication.shared.open(callbackUrl, options: [:], completionHandler: nil)
                                }
                            }),
                            TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})
                        ]
                    )
                    authContext.rootController.currentWindow?.present(alertController, on: .root, blockInteraction: false, completion: {})
                }
            }
        })
    }
    
    @discardableResult func handleUserActivity(_ userActivity: NSUserActivity) -> Bool {
        if #available(iOS 10.0, *) {
            var startCallContacts: [INPerson]?
            var isVideo = false
            if let startCallIntent = userActivity.interaction?.intent as? INStartCallIntent {
                startCallContacts = startCallIntent.contacts
                // Phone ▸ Recents and the app's donations say whether it was a video call.
                isVideo = startCallIntent.callCapability == .videoCall
            }
            
            if let startCallContacts = startCallContacts {
                let startCall: (PeerId) -> Void = { peerId in
                    self.startCallWhenReady(accountId: nil, peerId: peerId, isVideo: isVideo)
                }
                
                func cleanPhoneNumber(_ text: String) -> String {
                    var result = ""
                    for c in text {
                        if c == "+" {
                            if result.isEmpty {
                                result += String(c)
                            }
                        } else if c >= "0" && c <= "9" {
                            result += String(c)
                        }
                    }
                    return result
                }
                
                func matchPhoneNumbers(_ lhs: String, _ rhs: String) -> Bool {
                    if lhs.count < 10 && lhs.count == rhs.count {
                        return lhs == rhs
                    } else if lhs.count >= 10 && rhs.count >= 10 && lhs.suffix(10) == rhs.suffix(10) {
                        return true
                    } else {
                        return false
                    }
                }
                
                // A call the notification service extension rang (its donated INStartCallIntent):
                // call the caller back from the account the call came to, audio or video as it was.
                // CallKit handles (Phone ▸ Recents) and the app's own donations name the account the same way.
                if let contact = startCallContacts.first, let callBack = [contact.customIdentifier, contact.personHandle?.value].lazy.compactMap({ $0.flatMap(CallKitHandle.parse) }).first(where: { $0.accountId != nil }), let accountId = callBack.accountId {
                    self.startCallWhenReady(accountId: accountId, peerId: callBack.peerId, isVideo: isVideo)
                    return true
                }

                if let contact = startCallContacts.first {
                    let contactByIdentifier: Signal<EnginePeer?, NoError>
                    if let context = self.contextValue?.context, let contactIdentifier = contact.contactIdentifier {
                        contactByIdentifier = context.engine.contacts.findPeerByLocalContactIdentifier(identifier: contactIdentifier)
                    } else {
                        contactByIdentifier = .single(nil)
                    }
                    
                    let _ = (contactByIdentifier |> deliverOnMainQueue).start(next: { peerByContact in
                        var processed = false
                        if let peerByContact = peerByContact {
                            startCall(peerByContact.id)
                            processed = true
                        } else if let handle = contact.customIdentifier, handle.hasPrefix("tg"), let parsed = CallKitHandle.parse(handle) {
                            // "tg<raw user id>" (older call donations) or "tg<packed peer id>" (Siri).
                            startCall(parsed.peerId)
                            processed = true
                        }
                        if !processed, let handle = contact.personHandle, let value = handle.value {
                            switch handle.type {
                                case .unknown:
                                    // An older CallKit handle: the raw user id, which reads as a group when packed.
                                    if let parsed = CallKitHandle.parse(value) {
                                        startCall(parsed.peerId)
                                        processed = true
                                    }
                                case .phoneNumber:
                                    let phoneNumber = cleanPhoneNumber(value)
                                    if !phoneNumber.isEmpty {
                                        guard let context = self.contextValue?.context else {
                                            return
                                        }
                                        let _ = (context.engine.data.get(TelegramEngine.EngineData.Item.Contacts.List(includePresences: false))
                                        |> map { contactList -> PeerId? in
                                            var result: PeerId?
                                            for peer in contactList.peers {
                                                if case let .user(peer) = peer, let peerPhoneNumber = peer.phone {
                                                    if matchPhoneNumbers(phoneNumber, peerPhoneNumber) {
                                                        result = peer.id
                                                        break
                                                    }
                                                }
                                            }
                                            return result
                                        }
                                        |> deliverOnMainQueue).start(next: { peerId in
                                            if let peerId = peerId {
                                                startCall(peerId)
                                            }
                                        })
                                        processed = true
                                    }
                                default:
                                    break
                            }
                        }
                    })
                    
                    return true
                }
            } else if let sendMessageIntent = userActivity.interaction?.intent as? INSendMessageIntent {
                // A share-sheet or Siri suggestion: the chat it names, in the account suggestions are
                // donated from (not whichever account is current).
                if let target = SendMessageSuggestions.target(conversationIdentifier: sendMessageIntent.conversationIdentifier, recipientCustomIdentifiers: (sendMessageIntent.recipients ?? []).map(\.customIdentifier)) {
                    let _ = (self.sharedContextPromise.get()
                    |> take(1)
                    |> mapToSignal { sharedApplicationContext -> Signal<(AccountRecordId?, PeerId), NoError> in
                        let sharedContext = sharedApplicationContext.sharedContext
                        return combineLatest(
                            sharedContext.activeAccountContexts |> take(1),
                            sharedContext.accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.intentsSettings]) |> take(1)
                        )
                        |> map { accounts, sharedData -> (AccountRecordId?, PeerId) in
                            let settings = sharedData.entries[ApplicationSpecificSharedDataKeys.intentsSettings]?.get(IntentsSettings.self) ?? IntentsSettings.defaultSettings
                            let signedIn = accounts.accounts.map { (peerId: $0.1.account.peerId.toInt64(), id: $0.0) }
                            let accountPeerId = SendMessageSuggestions.accountPeerId(for: target, suggestionsAccountPeerId: settings.account?.toInt64(), signedInAccountPeerIds: signedIn.map(\.peerId))
                            return (signedIn.first(where: { $0.peerId == accountPeerId })?.id, PeerId(target.peerId))
                        }
                    }
                    |> deliverOnMainQueue).start(next: { [weak self] accountId, peerId in
                        self?.openChatWhenReady(accountId: accountId, peerId: peerId, threadId: nil, activateInput: true, storyId: nil)
                    })
                }
            }
        }
        
        if userActivity.activityType == NSUserActivityTypeBrowsingWeb, let url = userActivity.webpageURL {
            self.openUrl(url: url)
        }
        
        if userActivity.activityType == CSSearchableItemActionType {
            if let uniqueIdentifier = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String, uniqueIdentifier.hasPrefix("contact-") {
                if let peerIdValue = Int64(String(uniqueIdentifier[uniqueIdentifier.index(uniqueIdentifier.startIndex, offsetBy: "contact-".count)...])) {
                    let peerId = PeerId(peerIdValue)
                
                    let signal = self.sharedContextPromise.get()
                    |> take(1)
                    |> mapToSignal { sharedApplicationContext -> Signal<(AccountRecordId?, [AccountContext?]), NoError> in
                        return sharedApplicationContext.sharedContext.activeAccountContexts
                        |> take(1)
                        |> mapToSignal { primary, contexts, _ -> Signal<(AccountRecordId?, [AccountContext?]), NoError> in
                            return combineLatest(contexts.map { _, context, _ -> Signal<AccountContext?, NoError> in
                                return context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: peerId))
                                |> map { peer -> AccountContext? in
                                    if peer != nil {
                                        return context
                                    } else {
                                        return nil
                                    }
                                }
                            })
                            |> map { contexts -> (AccountRecordId?, [AccountContext?]) in
                                return (primary?.account.id, contexts)
                            }
                        }
                    }
                    let _ = (signal
                    |> deliverOnMainQueue).start(next: { primary, contexts in
                        if let primary = primary {
                            for context in contexts {
                                if let context = context, context.account.id == primary {
                                    self.openChatWhenReady(accountId: nil, peerId: peerId, threadId: nil, storyId: nil, openAppIfAny: true)
                                    return
                                }
                            }
                        }
                        
                        for context in contexts {
                            if let context = context {
                                self.openChatWhenReady(accountId: context.account.id, peerId: peerId, threadId: nil, storyId: nil, openAppIfAny: true)
                                return
                            }
                        }
                    })
                }
            }
        }
        
        return true
    }
    
    func handleShortcutItem(_ shortcutItem: UIApplicationShortcutItem, completionHandler: @escaping (Bool) -> Void) {
        let _ = (self.sharedContextPromise.get()
        |> take(1)
        |> deliverOnMainQueue).start(next: { sharedContext in
            let type = ApplicationShortcutItemType(rawValue: shortcutItem.type)
            let immediately = type == .account
            let proceed: () -> Void = {
                let _ = (self.context.get()
                |> take(1)
                |> deliverOnMainQueue).start(next: { context in
                    if let context = context {
                        if let type = type {
                            switch type {
                                case .search:
                                    context.openRootSearch()
                                case .compose:
                                    context.openRootCompose()
                                case .camera:
                                    context.openRootCamera()
                                case .savedMessages:
                                    self.openChatWhenReady(accountId: nil, peerId: context.context.account.peerId, threadId: nil, storyId: nil)
                                case .account:
                                    context.switchAccount()
                                case .appIcon:
                                    context.openAppIcon()
                            }
                        }
                    }
                })
            }
            if let appLockContext = sharedContext.sharedContext.appLockContext as? AppLockContextImpl, !immediately {
                let _ = (appLockContext.isCurrentlyLocked
                |> filter { !$0 }
                |> take(1)
                |> deliverOnMainQueue).start(next: { _ in
                    proceed()
                })
            } else {
                proceed()
            }
        })
    }
    
    private func openNotificationSettingsWhenReady() {
        let _ = (self.authorizedContext()
        |> take(1)
        |> deliverOnMainQueue).start(next: { context in
            context.openNotificationSettings()
        })
    }
    
    private func startCallWhenReady(accountId: AccountRecordId?, peerId: PeerId, isVideo: Bool) {
        let signal = self.sharedContextPromise.get()
        |> take(1)
        |> mapToSignal { sharedApplicationContext -> Signal<SharedApplicationContext, NoError> in
            guard let accountId = accountId else {
                return .single(sharedApplicationContext)
            }
            // A handle donated before its account signed out (or was removed): switching to it
            // would make a missing record the current account.
            return sharedApplicationContext.sharedContext.accountManager.accountRecords()
            |> take(1)
            |> mapToSignal { view -> Signal<SharedApplicationContext, NoError> in
                let accounts = view.records.map { record -> (id: Int64, isLoggedOut: Bool) in
                    let isLoggedOut = record.attributes.contains(where: { attribute in
                        if case .loggedOut = attribute {
                            return true
                        } else {
                            return false
                        }
                    })
                    return (id: record.id.int64, isLoggedOut: isLoggedOut)
                }
                let callBack = IncomingCallNotifications.CallBack(accountId: accountId.int64, peerId: peerId.toInt64())
                guard IncomingCallNotifications.callBackAccountId(callBack, accounts: accounts) != nil else {
                    Logger.shared.log("App \(self.episodeId)", "call back dropped: account \(accountId.int64) is not signed in")
                    return .complete()
                }
                return .single(sharedApplicationContext)
            }
        }
        // switchToAccount must run on the main queue; the promise and the account records can
        // deliver on the account manager's queue (a cold launch from Phone > Recents).
        |> deliverOnMainQueue
        |> mapToSignal { sharedApplicationContext -> Signal<AuthorizedApplicationContext, NoError> in
            if let accountId = accountId {
                sharedApplicationContext.sharedContext.switchToAccount(id: accountId)
                return self.authorizedContext()
                |> filter { context in
                    context.context.account.id == accountId
                }
                |> take(1)
            } else {
                return self.authorizedContext()
                |> take(1)
            }
        }
        self.openChatWhenReadyDisposable.set((signal
        |> deliverOnMainQueue).start(next: { context in
            context.startCall(peerId: peerId, isVideo: isVideo)
        }))
    }
    
    private func openChatWhenReady(accountId: AccountRecordId?, peerId: PeerId, threadId: Int64?, messageId: MessageId? = nil, activateInput: Bool = false, storyId: StoryId?, openAppIfAny: Bool = false, alwaysKeepMessageId: Bool = false) {
        if let messageId, messageId.namespace == Namespaces.Message.Cloud,
           peerId == PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value(777000)) {
            if self.walletTonConnectNotifications.enqueue(accountId: accountId, messageId: messageId, alwaysKeepMessageId: alwaysKeepMessageId) {
                self.openNextWalletTonConnectNotification()
            }
            return
        }

        let signal = self.sharedContextPromise.get()
        |> take(1)
        |> deliverOnMainQueue
        |> mapToSignal { sharedApplicationContext -> Signal<AuthorizedApplicationContext, NoError> in
            if let accountId = accountId {
                sharedApplicationContext.sharedContext.switchToAccount(id: accountId)
                return self.authorizedContext()
                |> filter { context in
                    context.context.account.id == accountId
                }
                |> take(1)
            } else {
                return self.authorizedContext()
                |> take(1)
            }
        }
        self.openChatWhenReadyDisposable.set((signal
        |> deliverOnMainQueue).start(next: { context in
            context.openChatWithPeerId(peerId: peerId, threadId: threadId, messageId: messageId, activateInput: activateInput, storyId: storyId, openAppIfAny: openAppIfAny, alwaysKeepMessageId: alwaysKeepMessageId)
        }))
    }
    
    private var walletTonConnectNotifications = WalletTonConnectNotificationQueue<AccountRecordId, MessageId>()
    private let walletTonConnectNotificationDisposable = MetaDisposable()

    private func openNextWalletTonConnectNotification() {
        guard let route = self.walletTonConnectNotifications.next() else { return }
        let signal = self.sharedContextPromise.get()
        |> take(1)
        |> deliverOnMainQueue
        |> mapToSignal { sharedContext -> Signal<AuthorizedApplicationContext, NoError> in
            if let id = route.accountId {
                sharedContext.sharedContext.switchToAccount(id: id)
                return self.authorizedContext() |> filter { $0.context.account.id == id } |> take(1)
            }
            return self.authorizedContext() |> take(1)
        }
        |> mapToSignal { context -> Signal<(AuthorizedApplicationContext, EngineMessage?), NoError> in
            context.context.engine.messages.downloadMessage(messageId: route.messageId)
            |> map { (context, $0) }
        }
        |> deliverOnMainQueue
        self.walletTonConnectNotificationDisposable.set(signal.start(next: { [weak self] context, message in
            guard let self else { return }
            let isWalletAvailable = WalletConfiguration.with(appConfiguration: context.context.currentAppConfiguration.with { $0 }).isAvailable
            if isWalletAvailable, let message, let request = walletTonConnectRequestRoute(message: message, accountPeerId: context.context.account.peerId) {
                context.context.walletContext?.openTonConnectRequest(sessionId: request.sessionId, messageId: request.messageId)
            } else {
                context.openChatWithPeerId(peerId: route.messageId.peerId, threadId: nil, messageId: route.messageId,
                    activateInput: false, storyId: nil, openAppIfAny: false, alwaysKeepMessageId: route.alwaysKeepMessageId)
                if !isWalletAvailable {
                    self.presentWalletUnavailable(in: context)
                }
            }
            self.walletTonConnectNotifications.complete()
            Queue.mainQueue().async { [weak self] in self?.openNextWalletTonConnectNotification() }
        }))
    }

    private var openUrlInProgress: URL?
    private func openUrlWhenReady(accountId: AccountRecordId? = nil, url: URL, external: Bool = false) {
        self.noteOpenUrlInProgress(url)
        
        let signal = self.sharedContextPromise.get()
        |> take(1)
        |> deliverOnMainQueue
        |> mapToSignal { sharedApplicationContext -> Signal<AuthorizedApplicationContext, NoError> in
            if let accountId = accountId {
                sharedApplicationContext.sharedContext.switchToAccount(id: accountId)
                return self.authorizedContext()
                |> filter { context in
                    context.context.account.id == accountId
                }
                |> take(1)
            } else {
                return self.authorizedContext()
                |> take(1)
            }
        }
        self.openUrlWhenReadyDisposable.set((signal
        |> deliverOnMainQueue).start(next: { [weak self] context in
            if (WalletContext.isTonConnectUrl(url.absoluteString) || url.scheme?.lowercased() == "ton"), !WalletConfiguration.with(appConfiguration: context.context.currentAppConfiguration.with { $0 }).isAvailable {
                self?.presentWalletUnavailable(in: context)
            } else if WalletContext.isTonConnectUrl(url.absoluteString) {
                context.context.walletContext?.processTonConnectUrl(url.absoluteString)
            } else if url.scheme?.lowercased() == "ton" {
                if isTonTransferUrl(url), let walletContext = context.context.walletContext {
                    context.rootController.pushViewController(WalletSendScreen(
                        context: context.context,
                        walletContext: walletContext,
                        address: url.absoluteString
                    ))
                }
            } else {
                context.openUrl(url, external: external)
            }
        }))
    }
    
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let _ = (accountIdFromNotification(response.notification, sharedContext: self.sharedContextPromise.get())
        |> deliverOnMainQueue).start(next: { accountId in
            if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
                if let dataUrl = response.notification.request.content.userInfo["url"] as? String {
                    if let url = URL(string: dataUrl) {
                        self.openUrlWhenReady(accountId: accountId, url: url, external: true)
                    }
                } else {
                    if let (peerId, threadId) = peerIdFromNotification(response.notification) {
                        var messageId: MessageId? = nil
                        if response.notification.request.content.categoryIdentifier == "c" || response.notification.request.content.categoryIdentifier == "t" {
                            messageId = messageIdFromNotification(peerId: peerId, notification: response.notification)
                        }
                        let storyId = storyIdFromNotification(peerId: peerId, notification: response.notification)
                        self.openChatWhenReady(accountId: accountId, peerId: peerId, threadId: threadId, messageId: messageId, storyId: storyId)
                    }
                }
                completionHandler()
            } else if response.actionIdentifier == "reply", let (peerId, threadId) = peerIdFromNotification(response.notification), let accountId = accountId {
                guard let response = response as? UNTextInputNotificationResponse, !response.userText.isEmpty else {
                    completionHandler()
                    return
                }
                let text = response.userText
                let signal = self.sharedContextPromise.get()
                |> take(1)
                |> deliverOnMainQueue
                |> mapToSignal { sharedContext -> Signal<Void, NoError> in
                    sharedContext.wakeupManager.allowBackgroundTimeExtension(timeout: 2.0, extendNow: true)
                    return sharedContext.sharedContext.activeAccountContexts
                    |> mapToSignal { _, contexts, _ -> Signal<Account, NoError> in
                        for context in contexts {
                            if context.1.account.id == accountId {
                                return .single(context.1.account)
                            }
                        }
                        return .complete()
                    }
                    |> take(1)
                    |> deliverOnMainQueue
                    |> mapToSignal { account -> Signal<Void, NoError> in
                        if let messageId = messageIdFromNotification(peerId: peerId, notification: response.notification) {
                            let _ = TelegramEngine(account: account).messages.applyMaxReadMessageIdInteractively(messageId: messageId).start()
                        }
                        var replyToMessageId: MessageId?
                        if let threadId {
                            replyToMessageId = MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: Int32(clamping: threadId))
                        }
                        return enqueueMessages(account: account, peerId: peerId, messages: [EnqueueMessage.message(text: text, attributes: [], inlineStickers: [:], mediaReference: nil, threadId: nil, replyToMessageId: replyToMessageId.flatMap { EngineMessageReplySubject(messageId: $0, quote: nil, innerSubject: nil) }, replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: [])])
                        |> map { messageIds -> MessageId? in
                            if messageIds.isEmpty {
                                return nil
                            } else {
                                return messageIds[0]
                            }
                        }
                        |> mapToSignal { messageId -> Signal<Void, NoError> in
                            if let messageId = messageId {
                                return account.postbox.unsentMessageIdsView()
                                |> filter { view in
                                    return !view.ids.contains(messageId)
                                }
                                |> take(1)
                                |> mapToSignal { _ -> Signal<Void, NoError> in
                                    return .complete()
                                }
                            } else {
                                return .complete()
                            }
                        }
                    }
                }
                |> deliverOnMainQueue
                
                let disposable = MetaDisposable()
                disposable.set((signal
                |> afterDisposed { [weak disposable] in
                    Queue.mainQueue().async {
                        if let disposable = disposable {
                            self.replyFromNotificationsDisposables.remove(disposable)
                        }
                        completionHandler()
                    }
                }).start())
                self.replyFromNotificationsDisposables.add(disposable)
            } else {
                completionHandler()
            }
        })
    }
    
    func requestNotificationTokenInvalidation() {
        UIApplication.shared.unregisterForRemoteNotifications()
        DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 1.0, execute: {
            UIApplication.shared.registerForRemoteNotifications()
        })
    }
    
    private func registerForNotifications(context: AccountContextImpl, authorize: Bool = true, completion: @escaping (Bool) -> Void = { _ in }) {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let _ = (context.sharedContext.accountManager.transaction { transaction -> Bool in
            let settings = transaction.getSharedData(ApplicationSpecificSharedDataKeys.inAppNotificationSettings)?.get(InAppNotificationSettings.self) ?? InAppNotificationSettings.defaultSettings
            return settings.displayNameOnLockscreen
        }
        |> deliverOnMainQueue).start(next: { displayNames in
            self.registerForNotifications(replyString: presentationData.strings.Notification_Reply, messagePlaceholderString: presentationData.strings.Conversation_InputTextPlaceholder, hiddenContentString: presentationData.strings.Watch_MessageView_Title, hiddenReactionContentString: presentationData.strings.Notification_LockScreenReactionPlaceholder, hiddenStoryContentString: presentationData.strings.Notification_LockScreenStoryPlaceholder, hiddenStoryReactionContentString: presentationData.strings.PUSH_REACT_STORY_HIDDEN, includeNames: displayNames, authorize: authorize, completion: completion)
        })
    }

    private func registerForNotifications(replyString: String, messagePlaceholderString: String, hiddenContentString: String, hiddenReactionContentString: String, hiddenStoryContentString: String, hiddenStoryReactionContentString: String, includeNames: Bool, authorize: Bool = true, completion: @escaping (Bool) -> Void = { _ in }) {
        let notificationCenter = UNUserNotificationCenter.current()
        Logger.shared.log("App \(self.episodeId)", "register for notifications: get settings (authorize: \(authorize))")
        notificationCenter.getNotificationSettings(completionHandler: { settings in
            Logger.shared.log("App \(self.episodeId)", "register for notifications: received settings: \(settings.authorizationStatus)")
            
            switch (settings.authorizationStatus, authorize) {
                case (.authorized, _), (.notDetermined, true):
                    var authorizationOptions: UNAuthorizationOptions = [.badge, .sound, .alert, .carPlay]
                    if #available(iOS 12.0, *) {
                        authorizationOptions.insert(.providesAppNotificationSettings)
                    }
                    Logger.shared.log("App \(self.episodeId)", "register for notifications: request authorization")
                    notificationCenter.requestAuthorization(options: authorizationOptions, completionHandler: { result, _ in
                        Logger.shared.log("App \(self.episodeId)", "register for notifications: received authorization: \(result)")
                        completion(result)
                        if result {
                            Queue.mainQueue().async {
                                let reply = UNTextInputNotificationAction(identifier: "reply", title: replyString, options: [], textInputButtonTitle: replyString, textInputPlaceholder: messagePlaceholderString)
                                                                    
                                let unknownMessageCategory: UNNotificationCategory
                                let repliableMessageCategory: UNNotificationCategory
                                let repliableMediaMessageCategory: UNNotificationCategory
                                let groupRepliableMessageCategory: UNNotificationCategory
                                let groupRepliableMediaMessageCategory: UNNotificationCategory
                                let channelMessageCategory: UNNotificationCategory
                                let reactionMessageCategory: UNNotificationCategory
                                let storyCategory: UNNotificationCategory
                                let storyReactionCategory: UNNotificationCategory
                                
                                var options: UNNotificationCategoryOptions = []
                                if includeNames {
                                    options.insert(.hiddenPreviewsShowTitle)
                                }
                                
                                var carPlayOptions = options
                                carPlayOptions.insert(.allowInCarPlay)
                                
                                unknownMessageCategory = UNNotificationCategory(identifier: "unknown", actions: [], intentIdentifiers: [], hiddenPreviewsBodyPlaceholder: hiddenContentString, options: options)
                                repliableMessageCategory = UNNotificationCategory(identifier: "r", actions: [reply], intentIdentifiers: [INSearchForMessagesIntentIdentifier], hiddenPreviewsBodyPlaceholder: hiddenContentString, options: carPlayOptions)
                                repliableMediaMessageCategory = UNNotificationCategory(identifier: "m", actions: [reply], intentIdentifiers: [], hiddenPreviewsBodyPlaceholder: hiddenContentString, options: carPlayOptions)
                                groupRepliableMessageCategory = UNNotificationCategory(identifier: "gr", actions: [reply], intentIdentifiers: [INSearchForMessagesIntentIdentifier], hiddenPreviewsBodyPlaceholder: hiddenContentString, options: carPlayOptions)
                                groupRepliableMediaMessageCategory = UNNotificationCategory(identifier: "gm", actions: [reply], intentIdentifiers: [], hiddenPreviewsBodyPlaceholder: hiddenContentString, options: carPlayOptions)
                                channelMessageCategory = UNNotificationCategory(identifier: "c", actions: [], intentIdentifiers: [], hiddenPreviewsBodyPlaceholder: hiddenContentString, options: options)
                                reactionMessageCategory = UNNotificationCategory(identifier: "t", actions: [], intentIdentifiers: [], hiddenPreviewsBodyPlaceholder: hiddenReactionContentString, options: options)
                                storyCategory = UNNotificationCategory(identifier: "st", actions: [], intentIdentifiers: [], hiddenPreviewsBodyPlaceholder: hiddenStoryContentString, options: options)
                                storyReactionCategory = UNNotificationCategory(identifier: "str", actions: [], intentIdentifiers: [], hiddenPreviewsBodyPlaceholder: hiddenStoryReactionContentString, options: options)
                                
                                UNUserNotificationCenter.current().setNotificationCategories([
                                    unknownMessageCategory,
                                    repliableMessageCategory,
                                    repliableMediaMessageCategory,
                                    channelMessageCategory,
                                    reactionMessageCategory,
                                    groupRepliableMessageCategory,
                                    groupRepliableMediaMessageCategory,
                                    storyCategory,
                                    storyReactionCategory
                                ])
                                
                                Logger.shared.log("App \(self.episodeId)", "register for notifications: invoke registerForRemoteNotifications")
                                UIApplication.shared.registerForRemoteNotifications()
                            }
                        }
                    })
                default:
                    break
            }
        })
    }
    
    @available(iOS 10.0, *)
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // The handler must be called exactly once on every path, or the system holds the block.
        let _ = (accountIdFromNotification(notification, sharedContext: self.sharedContextPromise.get())
        |> take(1)
        |> deliverOnMainQueue).start(next: { accountId in
            let showsBanner = ForegroundNotificationPresentation.showsBanner(notificationAccountId: accountId?.int64, currentAccountId: self.contextValue?.context.account.id.int64, hasUrl: notification.request.content.userInfo["url"] != nil)
            completionHandler(showsBanner ? [.banner, .list] : [])
        })
    }
    
    @available(iOS 12.0, *)
    func userNotificationCenter(_ center: UNUserNotificationCenter, openSettingsFor notification: UNNotification?) {
        self.openNotificationSettingsWhenReady()
    }
    
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        Logger.shared.log("App \(self.episodeId)", "handleEventsForBackgroundURLSession \(identifier)")
        completionHandler()
    }
    
    override var next: UIResponder? {
        if let context = self.contextValue, let controller = context.context.keyShortcutsController {
            return controller
        }
        return super.next
    }
    
    @objc func debugPressed() {
        let _ = (Logger.shared.collectShortLogFiles()
        |> deliverOnMainQueue).start(next: { logs in
            var activityItems: [Any] = []
            for (_, path) in logs {
                activityItems.append(URL(fileURLWithPath: path))
            }
            
            let activityController = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
            // On iPad a popover without an anchor raises an exception.
            if let window = self.window {
                anchorNativePopover(activityController, window: window, sourceView: nil)
            }
            
            self.window?.rootViewController?.present(activityController, animated: true, completion: nil)
        })
    }
    
    private func resetIntentsIfNeeded(context: AccountContextImpl) {
        let _ = (context.sharedContext.accountManager.transaction { transaction in
            let settings = transaction.getSharedData(ApplicationSpecificSharedDataKeys.intentsSettings)?.get(IntentsSettings.self) ?? IntentsSettings.defaultSettings
            if !settings.initiallyReset || settings.account == nil {
                if #available(iOS 10.0, *) {
                    Queue.mainQueue().async {
                        INInteraction.deleteAll()
                    }
                }
                transaction.updateSharedData(ApplicationSpecificSharedDataKeys.intentsSettings, { _ in
                    return PreferencesEntry(IntentsSettings(initiallyReset: true, account: context.account.peerId, contacts: settings.contacts, privateChats: settings.privateChats, savedMessages: settings.savedMessages, groups: settings.groups, onlyShared: settings.onlyShared))
                })
            }
        }).start()
    }
}

private func notificationPayloadKey(data: Data) -> Data? {
    if data.count < 8 {
        return nil
    }
    return data.subdata(in: 0 ..< 8)
}

@available(iOS 10.0, *)
private func accountIdFromNotification(_ notification: UNNotification, sharedContext: Signal<SharedApplicationContext, NoError>) -> Signal<AccountRecordId?, NoError> {
    if let id = notification.request.content.userInfo["accountId"] as? Int64 {
        return .single(AccountRecordId(rawValue: id))
    } else if let idString = notification.request.content.userInfo["accountId"] as? String, let id = Int64(idString) {
        return .single(AccountRecordId(rawValue: id))
    } else {
        var encryptedData: Data?
        if var encryptedPayload = notification.request.content.userInfo["p"] as? String {
            encryptedPayload = encryptedPayload.replacingOccurrences(of: "-", with: "+")
            encryptedPayload = encryptedPayload.replacingOccurrences(of: "_", with: "/")
            while encryptedPayload.count % 4 != 0 {
                encryptedPayload.append("=")
            }
            encryptedData = Data(base64Encoded: encryptedPayload)
        }
        if let encryptedData = encryptedData, let notificationKeyId = notificationPayloadKey(data: encryptedData) {
            return sharedContext
            |> take(1)
            |> mapToSignal { sharedContext -> Signal<AccountRecordId?, NoError> in
                return sharedContext.sharedContext.activeAccountContexts
                |> take(1)
                |> mapToSignal { _, contexts, _ -> Signal<AccountRecordId?, NoError> in
                    let keys = contexts.map { _, context, _ -> Signal<(AccountRecordId, MasterNotificationKey)?, NoError> in
                        return masterNotificationsKey(account: context.account, ignoreDisabled: true)
                        |> map { key in
                            return (context.account.id, key)
                        }
                    }
                    return combineLatest(keys)
                    |> map { keys -> AccountRecordId? in
                        for idAndKey in keys {
                            if let (id, key) = idAndKey, key.id == notificationKeyId {
                                return id
                            }
                        }
                        return nil
                    }
                }
            }
        } else if let userId = notification.request.content.userInfo["userId"] as? Int {
            return sharedContext
            |> take(1)
            |> mapToSignal { sharedContext -> Signal<AccountRecordId?, NoError> in
                return sharedContext.sharedContext.activeAccountContexts
                |> take(1)
                |> map { _, contexts, _ -> AccountRecordId? in
                    for (_, context, _) in contexts {
                        if Int(context.account.peerId.id._internalGetInt64Value()) == userId {
                            return context.account.id
                        }
                    }
                    return nil
                }
            }
        } else {
            return .single(nil)
        }
    }
}

@available(iOS 10.0, *)
private func peerIdFromNotification(_ notification: UNNotification) -> (peerId: PeerId, threadId: Int64?)? {
    let threadId = notification.request.content.userInfo["threadId"] as? Int64
    
    if let peerId = notification.request.content.userInfo["peerId"] as? Int64 {
        return (PeerId(peerId), threadId)
    } else if let peerIdString = notification.request.content.userInfo["peerId"] as? String, let peerId = Int64(peerIdString) {
        return (PeerId(peerId), threadId)
    } else {
        let payload = notification.request.content.userInfo
        var peerId: PeerId?
        if let fromId = payload["from_id"] {
            let fromIdValue = fromId as! NSString
            peerId = PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value(Int64(fromIdValue as String) ?? 0))
        } else if let fromId = payload["chat_id"] {
            let fromIdValue = fromId as! NSString
            peerId = PeerId(namespace: Namespaces.Peer.CloudGroup, id: PeerId.Id._internalFromInt64Value(Int64(fromIdValue as String) ?? 0))
        } else if let fromId = payload["channel_id"] {
            let fromIdValue = fromId as! NSString
            peerId = PeerId(namespace: Namespaces.Peer.CloudChannel, id: PeerId.Id._internalFromInt64Value(Int64(fromIdValue as String) ?? 0))
        } else if let fromId = payload["encryption_id"] {
            let fromIdValue = fromId as! NSString
            peerId = PeerId(namespace: Namespaces.Peer.SecretChat, id: PeerId.Id._internalFromInt64Value(Int64(fromIdValue as String) ?? 0))
        }
        
        if let peerId = peerId {
            return (peerId, threadId)
        } else {
            return nil
        }
    }
}

private func messageIdFromNotification(peerId: PeerId, notification: UNNotification) -> MessageId? {
    let payload = notification.request.content.userInfo
    if let messageIdNamespace = payload["messageId.namespace"] as? Int32, let messageIdId = payload["messageId.id"] as? Int32 {
        return MessageId(peerId: peerId, namespace: messageIdNamespace, id: messageIdId)
    }
    
    if let msgId = payload["msg_id"] {
        let msgIdValue = msgId as! NSString
        return MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: Int32(msgIdValue.intValue))
    }
    return nil
}

private func storyIdFromNotification(peerId: PeerId, notification: UNNotification) -> StoryId? {
    let payload = notification.request.content.userInfo
    if let storyId = payload["story_id"] {
        let storyIdValue = storyId as! NSString
        return StoryId(peerId: peerId, id: Int32(storyIdValue.intValue))
    }
    return nil
}

private func getMemoryConsumption() -> Int {
    guard let memory_offset = MemoryLayout.offset(of: \task_vm_info_data_t.min_address) else {
        return 0
    }
    let TASK_VM_INFO_COUNT = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let TASK_VM_INFO_REV1_COUNT = mach_msg_type_number_t(memory_offset / MemoryLayout<integer_t>.size)
    var info = task_vm_info_data_t()
    var count = TASK_VM_INFO_COUNT
    let kr = withUnsafeMutablePointer(to: &info) { infoPtr in
        infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPtr, &count)
        }
    }
    guard kr == KERN_SUCCESS, count >= TASK_VM_INFO_REV1_COUNT else {
        return 0
    }
    return Int(info.phys_footprint)
}

private final class NavigationBarOverflowMenuReferenceSource: ContextReferenceContentSource {
    private let sourceView: UIView

    init(sourceView: UIView) {
        self.sourceView = sourceView
    }

    func transitionInfo() -> ContextControllerReferenceViewInfo? {
        return ContextControllerReferenceViewInfo(referenceView: self.sourceView, contentAreaInScreenSpace: mainWindowScreenBounds)
    }
}
