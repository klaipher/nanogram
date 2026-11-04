import Foundation
import Postbox
import SwiftSignalKit
import MtProtoKit

/// Event types that may be sent to Telegram with `help.saveAppLog`. Empty on purpose: every event the
/// app produces is product analytics or telemetry (premium promo and account-deletion funnels, permission
/// split tests, download statistics, network telemetry), and none of it is needed for the app to work.
/// This is the single list to extend if an event is ever required.
let appLogEventTypesAllowedToLeaveDevice: Set<String> = []

func appLogEventMayLeaveDevice(type: String) -> Bool {
    return appLogEventTypesAllowedToLeaveDevice.contains(type)
}

func _internal_addAppLogEvent(postbox: Postbox, time: Double = Date().timeIntervalSince1970, type: String, peerId: PeerId? = nil, data: JSON = .dictionary([:])) {
    // Events that can never be sent are not even queued.
    if !appLogEventMayLeaveDevice(type: type) {
        return
    }
    let tag: PeerOperationLogTag = OperationLogTags.SynchronizeAppLogEvents
    let peerId = PeerId(0)
    let _ = (postbox.transaction { transaction in
        transaction.operationLogAddEntry(peerId: peerId, tag: tag, tagLocalIndex: .automatic, tagMergedIndex: .automatic, contents: SynchronizeAppLogEventsOperation(content: .add(time: time, type: type, peerId: peerId, data: data)))
    }).start()
}

func _internal_addAppLogEvent(transaction: Transaction, time: Double, type: String, data: JSON) {
    if !appLogEventMayLeaveDevice(type: type) {
        return
    }
    let tag: PeerOperationLogTag = OperationLogTags.SynchronizeAppLogEvents
    let peerId = PeerId(0)
    transaction.operationLogAddEntry(peerId: peerId, tag: tag, tagLocalIndex: .automatic, tagMergedIndex: .automatic, contents: SynchronizeAppLogEventsOperation(content: .add(time: time, type: type, peerId: peerId, data: data)))
}

public func invokeAppLogEventsSynchronization(postbox: Postbox) {
    let tag: PeerOperationLogTag = OperationLogTags.SynchronizeAppLogEvents
    let peerId = PeerId(0)
    
    let _ = (postbox.transaction { transaction in
        var topOperation: (SynchronizeSavedStickersOperation, Int32)?
        transaction.operationLogEnumerateEntries(peerId: peerId, tag: tag, { entry in
            if let operation = entry.contents as? SynchronizeSavedStickersOperation, case .sync = operation.content {
                topOperation = (operation, entry.tagLocalIndex)
            }
            return false
        })
        
        if let (_, topLocalIndex) = topOperation {
            let _ = transaction.operationLogRemoveEntry(peerId: peerId, tag: tag, tagLocalIndex: topLocalIndex)
        }
        
        transaction.operationLogAddEntry(peerId: peerId, tag: tag, tagLocalIndex: .automatic, tagMergedIndex: .automatic, contents: SynchronizeAppLogEventsOperation(content: .sync))
    }).start()
}
