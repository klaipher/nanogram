import Foundation
import ObjectiveC
import XCTest
import SwiftSignalKit
import Postbox
import TelegramCore
import AppBundle
@testable import HarnessAppContext

/// A genuine account (the composer harness's, networking off) seeded with a group chat whose
/// messages the forward flow reads, plus a user chat to forward them into.
///
/// Hostless: the test bundle carries `PresentationStrings.data` and `Localizable.strings`
/// (`//Telegram:InstantPagePreviewTestStrings`), and `ForwardFlowResources` points the app
/// bundle's lookups of those two at it, as `ChatListUITests` does.
final class ForwardFlowFixture {
    static let sourceGroupId = PeerId(namespace: Namespaces.Peer.CloudGroup, id: PeerId.Id._internalFromInt64Value(5001))
    static let destinationUserId = PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value(6001))

    let harnessAccount: HarnessAccount
    let context: HarnessAccountContext
    var account: Account {
        return self.harnessAccount.account
    }

    init(testCase: XCTestCase) {
        ForwardFlowResources.install()

        let done = XCTestExpectation(description: "account created")
        var harnessAccount: HarnessAccount?
        let disposable = HarnessAccount.make().start(next: { value in
            harnessAccount = value
            done.fulfill()
        })
        testCase.wait(for: [done], timeout: 60.0)
        disposable.dispose()
        self.harnessAccount = harnessAccount!
        self.context = HarnessAccountContext(account: harnessAccount!, settings: HarnessSettings())
    }

    static func userId(_ index: Int) -> PeerId {
        return PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value(Int64(7000 + index)))
    }

    static func user(_ id: PeerId, name: String) -> TelegramUser {
        return TelegramUser(id: id, accessHash: .personal(1), firstName: name, lastName: nil, username: nil, phone: nil, photo: [], botInfo: nil, restrictionInfo: nil, flags: [], emojiStatus: nil, usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil, subscriberCount: nil, verificationIconFileId: nil)
    }

    /// Stores `count` cloud messages in the source group, written by `authorCount` users in turn,
    /// and returns their ids in order. Message `i` has text `"Message i"`.
    func storeSourceMessages(count: Int, authorCount: Int, firstId: Int32 = 1, textForIndex: ((Int) -> String)? = nil, attributesForIndex: ((Int) -> [MessageAttribute])? = nil) -> [MessageId] {
        let groupId = ForwardFlowFixture.sourceGroupId
        let destinationId = ForwardFlowFixture.destinationUserId
        let signal = self.account.postbox.transaction { transaction -> [MessageId] in
            var peers: [Peer] = []
            peers.append(TelegramGroup(id: groupId, title: "Source group", photo: [], participantCount: authorCount + 1, role: .member, membership: .Member, flags: [], defaultBannedRights: nil, migrationReference: nil, creationDate: 0, version: 0))
            peers.append(ForwardFlowFixture.user(destinationId, name: "Destination"))
            // Enqueueing needs the account's own peer.
            peers.append(ForwardFlowFixture.user(HarnessAccount.harnessPeerId, name: "Me"))
            for i in 0 ..< authorCount {
                peers.append(ForwardFlowFixture.user(ForwardFlowFixture.userId(i), name: "Author \(i)"))
            }
            updatePeersCustom(transaction: transaction, peers: peers, update: { _, updated in updated })

            var storeMessages: [StoreMessage] = []
            for i in 0 ..< count {
                let id = MessageId(peerId: groupId, namespace: Namespaces.Message.Cloud, id: firstId + Int32(i))
                let text = textForIndex?(i) ?? "Message \(i)"
                storeMessages.append(StoreMessage(id: id, customStableId: nil, globallyUniqueId: nil, groupingKey: nil, threadId: nil, timestamp: 1_700_000_000 + Int32(i), flags: [.Incoming], tags: [], globalTags: [], localTags: [], forwardInfo: nil, authorId: ForwardFlowFixture.userId(i % max(1, authorCount)), text: text, attributes: attributesForIndex?(i) ?? [], media: []))
            }
            let _ = transaction.addMessages(storeMessages, location: .Random)
            return storeMessages.compactMap { message -> MessageId? in
                if case let .Id(id) = message.id {
                    return id
                }
                return nil
            }
        }
        return ForwardFlowFixture.wait(signal)
    }

    func messages(_ ids: [MessageId]) -> [Message] {
        let signal = self.account.postbox.transaction { transaction -> [Message] in
            return ids.compactMap { transaction.getMessage($0) }
        }
        return ForwardFlowFixture.wait(signal)
    }

    /// Blocks on a signal that does not deliver on the main queue (Postbox transactions, enqueue).
    static func wait<T>(_ signal: Signal<T, NoError>, timeout: Double = 30.0) -> T {
        let result = Atomic<T?>(value: nil)
        let semaphore = DispatchSemaphore(value: 0)
        let disposable = (signal |> take(1)).start(next: { value in
            let _ = result.swap(value)
            semaphore.signal()
        })
        let _ = semaphore.wait(timeout: .now() + timeout)
        disposable.dispose()
        return result.with { $0 }!
    }

    static func spin(until condition: () -> Bool, timeout: Double = 10.0) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                return false
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        return true
    }
}

/// Points the app bundle's lookups of the two localization resources at the test bundle, once per
/// process. Production bundle code is untouched.
enum ForwardFlowResources {
    private static var installed = false

    static func install() {
        if self.installed {
            return
        }
        self.installed = true
        for (original, replacement) in [
            (#selector(Bundle.path(forResource:ofType:)), #selector(Bundle.forwardFlowResourcePath(_:ofType:))),
            (#selector(Bundle.path(forResource:ofType:inDirectory:forLocalization:)), #selector(Bundle.forwardFlowLocalizedResourcePath(_:ofType:inDirectory:forLocalization:)))
        ] {
            method_exchangeImplementations(class_getInstanceMethod(Bundle.self, original)!, class_getInstanceMethod(Bundle.self, replacement)!)
        }
    }
}

private final class ForwardFlowBundleToken {}

private extension Bundle {
    @objc func forwardFlowResourcePath(_ name: String?, ofType type: String?) -> String? {
        if name == "PresentationStrings", type == "data", self == getAppBundle() {
            return Bundle(for: ForwardFlowBundleToken.self).forwardFlowResourcePath(name, ofType: type)
        }
        return self.forwardFlowResourcePath(name, ofType: type)
    }

    @objc func forwardFlowLocalizedResourcePath(_ name: String?, ofType type: String?, inDirectory directory: String?, forLocalization localization: String?) -> String? {
        if name == "Localizable", type == "strings", self == getAppBundle() {
            return Bundle(for: ForwardFlowBundleToken.self).forwardFlowLocalizedResourcePath(name, ofType: type, inDirectory: directory, forLocalization: localization)
        }
        return self.forwardFlowLocalizedResourcePath(name, ofType: type, inDirectory: directory, forLocalization: localization)
    }
}
