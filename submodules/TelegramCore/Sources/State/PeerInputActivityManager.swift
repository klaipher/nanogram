import Foundation
import Postbox
import SwiftSignalKit

private typealias SignalKitTimer = SwiftSignalKit.Timer

/// How long an unchanged activity keeps its update id before the next add of it issues a new one. In the local
/// manager a new update id sends the activity to the server again (messages.setTyping).
///
/// Our own typing is added on every keystroke, so upstream's 1 s re-sent it about once a second while typing. It is
/// re-sent after 4.5 s instead, still inside the receivers' display windows (TDLib 5.5 s, Telegram iOS 8 s; Telegram
/// Desktop re-sends its own typing on a keystroke every 5 s). Every other activity keeps 1 s: the
/// timer-driven ones (`acquireActivity`) rely on it, group-call speaking re-adds every 2 s against a 3 s receiver
/// timeout. Incoming activities (`isLocal == false`) keep 1 s too.
func peerInputActivityRefreshInterval(_ activity: PeerInputActivity, isLocal: Bool) -> Double {
    if isLocal, case .typingText = activity {
        return 4.5
    }
    return 1.0
}

/// Whether adding `current` over a record of `previous` added `elapsed` seconds ago issues a new update id.
/// A changed activity (kind, progress or payload) always does.
func peerInputActivityNeedsReissue(previous: PeerInputActivity, current: PeerInputActivity, elapsed: Double, isLocal: Bool) -> Bool {
    if previous != current {
        return true
    }
    return elapsed > peerInputActivityRefreshInterval(current, isLocal: isLocal)
}

private struct ActivityRecord {
    let peerId: PeerId
    let activity: PeerInputActivity
    let id: Int32
    let timer: SignalKitTimer
    let episodeId: Int32?
    let timestamp: Double
    let updateId: Int32
}

private final class PeerInputActivityContext {
    private let queue: Queue
    private let isLocal: Bool
    private let notifyEmpty: () -> Void
    private let notifyUpdated: () -> Void
    
    private var nextId: Int32 = 0
    private var activities: [ActivityRecord] = []
    
    private let subscribers = Bag<([(PeerId, PeerInputActivityRecord)]) -> Void>()
    
    private var scheduledUpdateSubscribers = false
    
    init(queue: Queue, isLocal: Bool, notifyEmpty: @escaping () -> Void, notifyUpdated: @escaping () -> Void) {
        self.queue = queue
        self.isLocal = isLocal
        self.notifyEmpty = notifyEmpty
        self.notifyUpdated = notifyUpdated
    }
    
    func addActivity(peerId: PeerId, activity: PeerInputActivity, timeout: Double, episodeId: Int32?, nextUpdateId: inout Int32) {
        assert(self.queue.isCurrent())
        
        let timestamp = CFAbsoluteTimeGetCurrent()
        
        var updated = false
        var found = false
        for i in 0 ..< self.activities.count {
            let record = self.activities[i]
            if record.peerId == peerId && record.activity.key == activity.key && record.episodeId == episodeId {
                found = true
                record.timer.invalidate()
                var updateId = record.updateId
                var recordTimestamp = record.timestamp
                if peerInputActivityNeedsReissue(previous: record.activity, current: activity, elapsed: timestamp - record.timestamp, isLocal: self.isLocal) {
                    updated = true
                    updateId = nextUpdateId
                    recordTimestamp = timestamp
                    nextUpdateId += 1
                }
                let currentId = record.id
                let timer = SignalKitTimer(timeout: timeout, repeat: false, completion: { [weak self] in
                    if let strongSelf = self {
                        for currentActivity in strongSelf.activities {
                            if currentActivity.id == currentId {
                                strongSelf.removeActivity(peerId: currentActivity.peerId, activity: currentActivity.activity, episodeId: currentActivity.episodeId)
                            }
                        }
                    }
                }, queue: self.queue, leeway: .precise)
                self.activities[i] = ActivityRecord(peerId: peerId, activity: activity, id: currentId, timer: timer, episodeId: episodeId, timestamp: recordTimestamp, updateId: updateId)
                timer.start()
                break
            }
        }
        
        if !found {
            updated = true
            let activityId = self.nextId
            self.nextId += 1
            let timer = SignalKitTimer(timeout: timeout, repeat: false, completion: { [weak self] in
                if let strongSelf = self {
                    for currentActivity in strongSelf.activities {
                        if currentActivity.id == activityId {
                            strongSelf.removeActivity(peerId: currentActivity.peerId, activity: currentActivity.activity, episodeId: currentActivity.episodeId)
                        }
                    }
                }
            }, queue: self.queue, leeway: .precise)
            let updateId = nextUpdateId
            nextUpdateId += 1
            self.activities.append(ActivityRecord(peerId: peerId, activity: activity, id: activityId, timer: timer, episodeId: episodeId, timestamp: timestamp, updateId: updateId))
            timer.start()
        }
        
        if updated {
            self.scheduleUpdateSubscribers()
        }
    }
    
    func removeActivity(peerId: PeerId, activity: PeerInputActivity, episodeId: Int32?) {
        assert(self.queue.isCurrent())
        
        for i in 0 ..< self.activities.count {
            let record = self.activities[i]
            if record.peerId == peerId && record.activity.key == activity.key && record.episodeId == episodeId {
                self.activities.remove(at: i)
                record.timer.invalidate()
                self.scheduleUpdateSubscribers()
                break
            }
        }
    }
    
    func removeAllActivities(peerId: PeerId) {
        assert(self.queue.isCurrent())
        
        var updated = false
        for i in (0 ..< self.activities.count).reversed() {
            let record = self.activities[i]
            if record.peerId == peerId {
                record.timer.invalidate()
                self.activities.remove(at: i)
                updated = true
            }
        }
        
        if updated {
            self.scheduleUpdateSubscribers()
        }
    }
    
    func scheduleUpdateSubscribers() {
        if !self.scheduledUpdateSubscribers {
            self.scheduledUpdateSubscribers = true
            
            self.queue.async { [weak self] in
                self?.updateSubscribers()
            }
        }
    }
    
    func isEmpty() -> Bool {
        return self.activities.isEmpty && self.subscribers.isEmpty
    }
    
    func topActivities() -> [(PeerId, PeerInputActivityRecord)] {
        var peerIds = Set<PeerId>()
        var result: [(PeerId, PeerInputActivityRecord)] = []
        for record in self.activities {
            if !peerIds.contains(record.peerId) {
                peerIds.insert(record.peerId)
                result.append((record.peerId, PeerInputActivityRecord(activity: record.activity, updateId: record.updateId)))
                if result.count == 10 {
                    break
                }
            }
        }
        return result
    }
    
    func updateSubscribers() {
        self.scheduledUpdateSubscribers = false
        
        if self.isEmpty() {
            self.notifyEmpty()
        } else {
            let topActivities = self.topActivities()
            for subscriber in self.subscribers.copyItems() {
                subscriber(topActivities)
            }
            
            self.notifyUpdated()
        }
    }
    
    func addSubscriber(_ subscriber: @escaping ([(PeerId, PeerInputActivityRecord)]) -> Void) -> Int {
        return self.subscribers.add(subscriber)
    }
    
    func removeSubscriber(_ index: Int) {
        self.subscribers.remove(index)
    }
}

private final class PeerGlobalInputActivityContext {
    private let subscribers = Bag<([PeerActivitySpace: [(PeerId, PeerInputActivityRecord)]]) -> Void>()
    
    func addSubscriber(_ subscriber: @escaping ([PeerActivitySpace: [(PeerId, PeerInputActivityRecord)]]) -> Void) -> Int {
        return self.subscribers.add(subscriber)
    }
    
    func removeSubscriber(_ index: Int) {
        self.subscribers.remove(index)
    }
    
    var isEmpty: Bool {
        return self.subscribers.isEmpty
    }
    
    func notify(_ activities: [PeerActivitySpace: [(PeerId, PeerInputActivityRecord)]]) {
        for subscriber in self.subscribers.copyItems() {
            subscriber(activities)
        }
    }
}

final class PeerInputActivityManager {
    private final class Impl {
        let queue: Queue
        let isLocal: Bool
        
        var nextEpisodeId: Int32 = 0
        var nextUpdateId: Int32 = 0
        var contexts: [PeerActivitySpace: PeerInputActivityContext] = [:]
        var globalContext: PeerGlobalInputActivityContext?
        
        init(queue: Queue, isLocal: Bool) {
            self.queue = queue
            self.isLocal = isLocal
        }
        
        func activities(peerId: PeerActivitySpace, onNext: @escaping ([(PeerId, PeerInputActivityRecord)]) -> Void) -> Disposable {
            let context: PeerInputActivityContext
            if let currentContext = self.contexts[peerId] {
                context = currentContext
            } else {
                context = PeerInputActivityContext(queue: queue, isLocal: self.isLocal, notifyEmpty: { [weak self] in
                    guard let self else {
                        return
                    }
                    self.contexts.removeValue(forKey: peerId)
                    
                    self.notifyGlobal()
                }, notifyUpdated: { [weak self] in
                    guard let self else {
                        return
                    }
                    self.notifyGlobal()
                })
                self.contexts[peerId] = context
            }
            let index = context.addSubscriber({ next in
                onNext(next)
            })
            onNext(context.topActivities())
            let queue = self.queue
            return ActionDisposable { [weak self] in
                queue.async {
                    guard let self else {
                        return
                    }
                    if let currentContext = self.contexts[peerId] {
                        currentContext.removeSubscriber(index)
                        if currentContext.isEmpty() {
                            self.contexts.removeValue(forKey: peerId)
                        }
                    }
                }
            }
        }
        
        func allActivities(onNext: @escaping ([PeerActivitySpace: [(PeerId, PeerInputActivityRecord)]]) -> Void) -> Disposable {
            let context: PeerGlobalInputActivityContext
            if let current = self.globalContext {
                context = current
            } else {
                context = PeerGlobalInputActivityContext()
                self.globalContext = context
            }
            let index = context.addSubscriber({ next in
                onNext(next)
            })
            onNext(self.collectActivities())
            
            let queue = self.queue
            return ActionDisposable { [weak self] in
                queue.async {
                    guard let self else {
                        return
                    }
                    if let currentContext = self.globalContext {
                        currentContext.removeSubscriber(index)
                        if currentContext.isEmpty {
                            self.globalContext = nil
                        }
                    }
                }
            }
        }
        
        // Contexts report every real change via notifyUpdated/notifyEmpty; the direct notifies in add/remove duplicated them.
        private func notifyGlobal() {
            if let globalContext = self.globalContext {
                globalContext.notify(self.collectActivities())
            }
        }
        
        private func collectActivities() -> [PeerActivitySpace: [(PeerId, PeerInputActivityRecord)]] {
            assert(self.queue.isCurrent())
            
            var dict: [PeerActivitySpace: [(PeerId, PeerInputActivityRecord)]] = [:]
            for (chatPeerId, context) in self.contexts {
                dict[chatPeerId] = context.topActivities()
            }
            return dict
        }
        
        func addActivity(chatPeerId: PeerActivitySpace, peerId: PeerId, activity: PeerInputActivity, episodeId: Int32?) {
            let context: PeerInputActivityContext
            if let currentContext = self.contexts[chatPeerId] {
                context = currentContext
            } else {
                context = PeerInputActivityContext(queue: self.queue, isLocal: self.isLocal, notifyEmpty: { [weak self] in
                    guard let self else {
                        return
                    }
                    self.contexts.removeValue(forKey: chatPeerId)
                    
                    self.notifyGlobal()
                }, notifyUpdated: { [weak self] in
                    guard let self else {
                        return
                    }
                    self.notifyGlobal()
                })
                self.contexts[chatPeerId] = context
            }
            
            let timeout: Double
            switch activity {
            case .interactingWithEmoji:
                timeout = 2.0
            case .speakingInGroupCall, .seeingEmojiInteraction:
                timeout = 3.0
            default:
                timeout = 8.0
            }
            
            if activity == .choosingSticker {
                context.removeActivity(peerId: peerId, activity: .typingText, episodeId: nil)
            }
            
            // The context reports actual changes through notifyUpdated/notifyEmpty.
            context.addActivity(peerId: peerId, activity: activity, timeout: timeout, episodeId: episodeId, nextUpdateId: &self.nextUpdateId)
        }
        
        func removeActivity(chatPeerId: PeerActivitySpace, peerId: PeerId, activity: PeerInputActivity, episodeId: Int32?) {
            if let context = self.contexts[chatPeerId] {
                context.removeActivity(peerId: peerId, activity: activity, episodeId: episodeId)
            }
        }
        
        func removeAllActivities(chatPeerId: PeerActivitySpace, peerId: PeerId) {
            if let currentContext = self.contexts[chatPeerId] {
                currentContext.removeAllActivities(peerId: peerId)
            }
        }
        
        func acquireActivity(chatPeerId: PeerActivitySpace, peerId: PeerId, activity: PeerInputActivity) -> Disposable {
            let queue = self.queue
            let episodeId = self.nextEpisodeId
            self.nextEpisodeId += 1
            
            let update: () -> Void = { [weak self] in
                guard let self else {
                    return
                }
                self.addActivity(chatPeerId: chatPeerId, peerId: peerId, activity: activity, episodeId: episodeId)
            }
            
            let timeout: Double
            switch activity {
            case .speakingInGroupCall:
                timeout = 2.0
            default:
                timeout = 5.0
            }
            
            let timer = SignalKitTimer(timeout: timeout, repeat: true, completion: {
                update()
            }, queue: queue, leeway: .precise)
            timer.start()
            update()
            
            return ActionDisposable { [weak self] in
                queue.async {
                    timer.invalidate()
                    
                    guard let self else {
                        return
                    }
                    self.removeActivity(chatPeerId: chatPeerId, peerId: peerId, activity: activity, episodeId: episodeId)
                }
            }
        }
    }
    
    private let queue = Queue()
    private let impl: QueueLocalObject<Impl>
    
    /// `isLocal`: the manager of our own activities, which are sent to the server (see `peerInputActivityRefreshInterval`).
    init(isLocal: Bool = false) {
        let queue = self.queue
        self.impl = QueueLocalObject(queue: queue, generate: {
            return Impl(queue: queue, isLocal: isLocal)
        })
    }
    
    func activities(peerId: PeerActivitySpace) -> Signal<[(PeerId, PeerInputActivityRecord)], NoError> {
        return self.impl.signalWith { impl, subscriber in
            return impl.activities(peerId: peerId, onNext: subscriber.putNext)
        }
    }
    
    func allActivities() -> Signal<[PeerActivitySpace: [(PeerId, PeerInputActivityRecord)]], NoError> {
        return self.impl.signalWith { impl, subscriber in
            return impl.allActivities(onNext: subscriber.putNext)
        }
    }
    
    func addActivity(chatPeerId: PeerActivitySpace, peerId: PeerId, activity: PeerInputActivity, episodeId: Int32? = nil) {
        self.impl.with { impl in
            impl.addActivity(chatPeerId: chatPeerId, peerId: peerId, activity: activity, episodeId: episodeId)
        }
    }
    
    func removeActivity(chatPeerId: PeerActivitySpace, peerId: PeerId, activity: PeerInputActivity, episodeId: Int32? = nil) {
        self.impl.with { impl in
            impl.removeActivity(chatPeerId: chatPeerId, peerId: peerId, activity: activity, episodeId: episodeId)
        }
    }
    
    func removeAllActivities(chatPeerId: PeerActivitySpace, peerId: PeerId) {
        self.impl.with { impl in
            impl.removeAllActivities(chatPeerId: chatPeerId, peerId: peerId)
        }
    }
    
    func transaction(_ f: @escaping (PeerInputActivityManager) -> Void) {
        self.queue.async {
            f(self)
        }
    }
    
    func acquireActivity(chatPeerId: PeerActivitySpace, peerId: PeerId, activity: PeerInputActivity) -> Disposable {
        let disposable = MetaDisposable()
        self.impl.with { impl in
            disposable.set(impl.acquireActivity(chatPeerId: chatPeerId, peerId: peerId, activity: activity))
        }
        return disposable
    }
}
