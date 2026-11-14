import Foundation
import UIKit
import SwiftSignalKit
import TelegramCore
import AccountContext
import TelegramUIPreferences
import TelegramPresentationData
import AppLock
import WidgetKit
import NanogramGlance
#if canImport(ActivityKit)
import ActivityKit
#endif

typealias GlanceAccounts = (primary: AccountContext?, accounts: [(id: AccountRecordId, context: AccountContext)])

struct GlanceActivityRequest: Equatable {
    var kind: GlanceActivityKind
    var accountId: Int64
    var peerId: Int64
    var stopLabel: String
    var headline: String
    var status: String
    var startedAt: Date
    var endsAt: Date?
    var staleDate: Date
}

#if canImport(ActivityKit)
/// One Live Activity of one kind. Activities left over from a killed process are ended when the controller starts,
/// since what to show is derived again from the live state.
@available(iOS 16.2, *)
private final class GlanceActivityController {
    private var activity: Activity<NanogramGlanceActivityAttributes>?
    private var current: GlanceActivityRequest?
    
    init(kind: GlanceActivityKind) {
        for leftover in Activity<NanogramGlanceActivityAttributes>.activities where leftover.attributes.kind == kind {
            Task {
                await leftover.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
    
    func apply(_ request: GlanceActivityRequest?) {
        if request == self.current {
            return
        }
        self.current = request
        guard let request else {
            self.end()
            return
        }
        let state = NanogramGlanceActivityAttributes.ContentState(headline: request.headline, status: request.status, startedAt: request.startedAt, endsAt: request.endsAt)
        let content = ActivityContent(state: state, staleDate: request.staleDate)
        if let activity = self.activity, activity.attributes.accountId == request.accountId, activity.attributes.peerId == request.peerId {
            Task {
                await activity.update(content)
            }
            return
        }
        self.end()
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            return
        }
        let attributes = NanogramGlanceActivityAttributes(kind: request.kind, accountId: request.accountId, peerId: request.peerId, stopLabel: request.stopLabel)
        self.activity = try? Activity.request(attributes: attributes, content: content, pushType: nil)
    }
    
    private func end() {
        guard let activity = self.activity else {
            return
        }
        self.activity = nil
        Task {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
#endif

/// Feeds the glanceables (IOS-WIDGET-1, IOS-LIVEACT-1, IOS-APPINTENTS-1) while the Debug switch is on: the app group
/// snapshot the widget and intents read, the Live Activities of live location and of calls without CallKit, and the
/// handler the App Intents call into. With the switch off it writes a disabled snapshot and ends every activity.
final class GlanceCoordinator {
    private let rootPath: String
    private let navigateToChat: (AccountRecordId, EnginePeer.Id) -> Void
    private let accountsValue = Atomic<GlanceAccounts>(value: (nil, []))
    private let gateValue = Atomic<GlanceGate>(value: GlanceGate(enabled: false, displayNames: false, locked: true))
    private let currentCall = Atomic<PresentationCall?>(value: nil)
    private let disposables = DisposableSet()
    private var lastSnapshot: GlanceSnapshot?
    private var lastGate: GlanceGate?
    private var locationController: AnyObject?
    private var callController: AnyObject?
    private var callStartedAt: Date?
    
    init(rootPath: String, accountManager: AccountManager<TelegramAccountManagerTypes>, accounts: Signal<GlanceAccounts, NoError>, isLocked: Signal<Bool, NoError>, presentationData: Signal<PresentationData, NoError>, callManager: PresentationCallManager?, navigateToChat: @escaping (AccountRecordId, EnginePeer.Id) -> Void) {
        self.rootPath = rootPath
        self.navigateToChat = navigateToChat
        
        if #available(iOS 16.2, *) {
            #if canImport(ActivityKit)
            self.locationController = GlanceActivityController(kind: .liveLocation)
            self.callController = GlanceActivityController(kind: .call)
            #endif
        }
        
        let settings: Signal<(enabled: Bool, displayNames: Bool), NoError> = accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.experimentalUISettings, ApplicationSpecificSharedDataKeys.inAppNotificationSettings])
        |> map { sharedData -> (enabled: Bool, displayNames: Bool) in
            let experimental = sharedData.entries[ApplicationSpecificSharedDataKeys.experimentalUISettings]?.get(ExperimentalUISettings.self) ?? ExperimentalUISettings.defaultSettings
            let inApp = sharedData.entries[ApplicationSpecificSharedDataKeys.inAppNotificationSettings]?.get(InAppNotificationSettings.self) ?? InAppNotificationSettings.defaultSettings
            return (experimental.nanogramGlanceables, inApp.displayNameOnLockscreen)
        }
        let gate: Signal<GlanceGate, NoError> = combineLatest(queue: Queue.mainQueue(), settings, isLocked)
        |> map { settings, locked -> GlanceGate in
            return GlanceGate(enabled: settings.enabled, displayNames: settings.displayNames, locked: locked)
        }
        |> distinctUntilChanged
        let strings = presentationData
        |> map { $0.strings }
        |> distinctUntilChanged
        
        self.disposables.add((accounts |> deliverOnMainQueue).start(next: { [weak self] value in
            let _ = self?.accountsValue.swap(value)
        }))
        self.disposables.add((gate |> deliverOnMainQueue).start(next: { [weak self] value in
            let _ = self?.gateValue.swap(value)
        }))
        
        // The snapshot: chats only while the feature is on and the app is unlocked.
        let peers: Signal<[GlancePeerRef], NoError> = combineLatest(queue: Queue.mainQueue(), gate, accounts, strings)
        |> mapToSignal { gate, accounts, strings -> Signal<[GlancePeerRef], NoError> in
            if !gate.listsChats || accounts.accounts.isEmpty {
                return .single([])
            }
            var signals: [Signal<[GlancePeerRef], NoError>] = []
            for (id, context) in accounts.accounts {
                let accountPeerId = context.account.peerId
                signals.append(context.engine.messages.chatList(group: .root, count: 12)
                |> map { list -> [GlancePeerRef] in
                    var result: [GlancePeerRef] = []
                    for item in list.items {
                        guard case let .chatList(peerId) = item.id, let peer = item.renderedPeer.peer else {
                            continue
                        }
                        let isSaved = peerId == accountPeerId
                        result.append(GlancePeerRef(accountId: id.int64, peerId: peerId.toInt64(), title: isSaved ? strings.DialogList_SavedMessages : peer.debugDisplayTitle, isSavedMessages: isSaved))
                    }
                    return result
                }
                |> distinctUntilChanged)
            }
            return combineLatest(queue: Queue.mainQueue(), signals)
            |> map { lists -> [GlancePeerRef] in
                return lists.flatMap { $0 }
            }
        }
        |> distinctUntilChanged
        
        self.disposables.add((combineLatest(queue: Queue.mainQueue(), gate, accounts, strings, peers)
        |> deliverOnMainQueue).start(next: { [weak self] gate, accounts, strings, peers in
            self?.writeSnapshot(gate: gate, accounts: accounts, strings: strings, peers: peers)
        }))
        
        self.disposables.add((combineLatest(queue: Queue.mainQueue(), gate, accounts, strings)
        |> mapToSignal { gate, accounts, strings -> Signal<GlanceActivityRequest?, NoError> in
            return GlanceCoordinator.liveLocationRequest(gate: gate, accounts: accounts, strings: strings)
        }
        |> distinctUntilChanged
        |> deliverOnMainQueue).start(next: { [weak self] request in
            self?.applyActivity(kind: .liveLocation, request: request)
        }))
        
        if let callManager {
            self.disposables.add((combineLatest(queue: Queue.mainQueue(), gate, strings, callManager.currentCallSignal)
            |> mapToSignal { gate, strings, call -> Signal<(PresentationCall?, GlanceActivityRequest?), NoError> in
                guard gate.enabled, let call else {
                    return .single((call, nil))
                }
                return combineLatest(queue: Queue.mainQueue(), call.state, call.isIntegratedWithCallKitSignal)
                |> map { state, isIntegratedWithCallKit -> (PresentationCall?, GlanceActivityRequest?) in
                    return (call, GlanceCoordinator.callRequest(gate: gate, strings: strings, call: call, state: state, isIntegratedWithCallKit: isIntegratedWithCallKit))
                }
            }
            |> deliverOnMainQueue).start(next: { [weak self] call, request in
                guard let self else {
                    return
                }
                let _ = self.currentCall.swap(call)
                if request == nil {
                    self.callStartedAt = nil
                }
                self.applyActivity(kind: .call, request: request.map { request in
                    var request = request
                    let startedAt = self.callStartedAt ?? request.startedAt
                    self.callStartedAt = startedAt
                    request.startedAt = startedAt
                    return request
                })
            }))
        }
        
        let handler = GlanceIntentHandler(
            openChat: { [weak self] accountId, peerId in
                return await withCheckedContinuation { continuation in
                    Queue.mainQueue().async {
                        guard let self else {
                            continuation.resume(returning: false)
                            return
                        }
                        self.navigateToChat(AccountRecordId(rawValue: accountId), EnginePeer.Id(peerId))
                        continuation.resume(returning: true)
                    }
                }
            },
            sendToSavedMessages: { [weak self] accountId, text in
                return await withCheckedContinuation { continuation in
                    Queue.mainQueue().async {
                        guard let self else {
                            continuation.resume(returning: .unavailable)
                            return
                        }
                        continuation.resume(returning: self.sendToSavedMessages(accountId: accountId, text: text))
                    }
                }
            },
            stopLiveLocation: { [weak self] accountId, peerId in
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    Queue.mainQueue().async {
                        let accounts = self?.accountsValue.with { $0 }
                        let context = accounts?.accounts.first(where: { $0.id.int64 == accountId })?.context
                        context?.liveLocationManager?.cancelLiveLocation(peerId: EnginePeer.Id(peerId))
                        continuation.resume()
                    }
                }
            },
            endCall: { [weak self] in
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    Queue.mainQueue().async {
                        let _ = self?.currentCall.with { $0 }?.hangUp().start()
                        continuation.resume()
                    }
                }
            }
        )
        Task {
            await GlanceIntentBridge.shared.register(handler)
        }
    }
    
    deinit {
        self.disposables.dispose()
        Task {
            await GlanceIntentBridge.shared.register(nil)
        }
    }
    
    private func writeSnapshot(gate: GlanceGate, accounts: GlanceAccounts, strings: PresentationStrings, peers: [GlancePeerRef]) {
        var saved: GlancePeerRef?
        if gate.enabled, let primary = accounts.primary {
            saved = GlancePeerRef(accountId: primary.account.id.int64, peerId: primary.account.peerId.toInt64(), title: strings.DialogList_SavedMessages, isSavedMessages: true)
        }
        let snapshot = GlanceSnapshotBuilder.make(gate: gate, peers: peers, savedMessages: saved)
        if self.lastSnapshot.map({ !snapshot.hasSameContent(as: $0) }) ?? true {
            self.lastSnapshot = snapshot
            GlanceStore.write(snapshot, rootPath: self.rootPath)
        }
        let previousGate = self.lastGate
        self.lastGate = gate
        if previousGate != nil && (previousGate?.enabled != gate.enabled || previousGate?.displayNames != gate.displayNames) {
            DispatchQueue.global(qos: .background).async {
                #if arch(arm64) || arch(x86_64)
                WidgetCenter.shared.reloadTimelines(ofKind: "Nanogram_GlanceChats")
                #endif
            }
        }
    }
    
    private func applyActivity(kind: GlanceActivityKind, request: GlanceActivityRequest?) {
        if #available(iOS 16.2, *) {
            #if canImport(ActivityKit)
            let controller = (kind == .liveLocation ? self.locationController : self.callController) as? GlanceActivityController
            controller?.apply(request)
            #endif
        }
    }
    
    private func sendToSavedMessages(accountId: Int64?, text: String) -> GlanceSendResult {
        let gate = self.gateValue.with { $0 }
        if !gate.enabled {
            return .unavailable
        }
        if !gate.allowsSending {
            return .locked
        }
        let accounts = self.accountsValue.with { $0 }
        let context: AccountContext?
        if let accountId {
            context = accounts.accounts.first(where: { $0.id.int64 == accountId })?.context
        } else {
            context = accounts.primary
        }
        guard let context else {
            return .unavailable
        }
        // Keeps the process alive a little longer, so the queued message can leave.
        let application = UIApplication.shared
        var task: UIBackgroundTaskIdentifier = .invalid
        task = application.beginBackgroundTask(withName: "glance-send", expirationHandler: {
            application.endBackgroundTask(task)
        })
        let _ = (context.engine.messages.enqueueOutgoingMessage(to: context.account.peerId, replyTo: nil, content: .text(text, []))
        |> deliverOnMainQueue).start(completed: {
            Queue.mainQueue().after(15.0, {
                application.endBackgroundTask(task)
            })
        })
        return .queued
    }
    
    private static func liveLocationRequest(gate: GlanceGate, accounts: GlanceAccounts, strings: PresentationStrings) -> Signal<GlanceActivityRequest?, NoError> {
        if !gate.enabled {
            return .single(nil)
        }
        var signals: [Signal<[(accountId: Int64, message: EngineMessage)], NoError>] = []
        for (id, context) in accounts.accounts {
            guard let manager = context.liveLocationManager else {
                continue
            }
            signals.append(manager.summaryManager.broadcastingToMessages()
            |> map { messages -> [(accountId: Int64, message: EngineMessage)] in
                return messages.values.map { (accountId: id.int64, message: $0) }
            })
        }
        if signals.isEmpty {
            return .single(nil)
        }
        return combineLatest(queue: Queue.mainQueue(), signals)
        |> map { lists -> GlanceActivityRequest? in
            let all = lists.flatMap { $0 }.sorted(by: { $0.message.timestamp < $1.message.timestamp })
            guard let first = all.first else {
                return nil
            }
            let now = Date()
            var endsAt: Date?
            for media in first.message.media {
                if let map = media as? TelegramMediaMap, let timeout = map.liveBroadcastingTimeout, timeout > 0, timeout < Int32.max {
                    endsAt = Date(timeIntervalSince1970: Double(first.message.timestamp) + Double(timeout))
                }
            }
            let showsNames = GlanceVisibility.showsNames(surface: .lockScreen, lock: gate.lockPhase, displayNameOnLockscreen: gate.displayNames)
            let name = all.count == 1 ? first.message.peers[first.message.id.peerId]?.debugDisplayTitle : nil
            return GlanceActivityRequest(
                kind: .liveLocation,
                accountId: first.accountId,
                peerId: first.message.id.peerId.toInt64(),
                stopLabel: strings.Map_StopLiveLocation,
                headline: GlanceActivityPolicy.headline(base: strings.Map_LiveLocationTitle, name: name, showsNames: showsNames),
                status: strings.LiveLocation_MenuChatsCount(Int32(all.count)),
                startedAt: Date(timeIntervalSince1970: Double(first.message.timestamp)),
                endsAt: endsAt,
                staleDate: GlanceActivityPolicy.staleDate(expiresAt: endsAt, now: now, fallback: 8.0 * 3600.0)
            )
        }
    }
    
    private static func callRequest(gate: GlanceGate, strings: PresentationStrings, call: PresentationCall, state: PresentationCallState, isIntegratedWithCallKit: Bool) -> GlanceActivityRequest? {
        if isIntegratedWithCallKit {
            return nil
        }
        let now = Date()
        let status: String
        var startedAt = now
        switch state.state {
        case .waiting, .ringing, .requesting, .connecting:
            status = strings.Call_StatusConnecting
        case let .active(timestamp, _, _), let .reconnecting(timestamp, _, _):
            status = strings.Call_CallInProgressTitle
            startedAt = Date(timeIntervalSinceReferenceDate: timestamp)
        case .terminating, .terminated:
            return nil
        }
        let showsNames = GlanceVisibility.showsNames(surface: .lockScreen, lock: gate.lockPhase, displayNameOnLockscreen: gate.displayNames)
        return GlanceActivityRequest(
            kind: .call,
            accountId: call.context.account.id.int64,
            peerId: call.peerId.toInt64(),
            stopLabel: strings.Call_End.capitalized,
            headline: GlanceActivityPolicy.headline(base: strings.Conversation_Call, name: call.peer?.debugDisplayTitle, showsNames: showsNames),
            status: status,
            startedAt: startedAt,
            endsAt: nil,
            staleDate: now.addingTimeInterval(4.0 * 3600.0)
        )
    }
}
