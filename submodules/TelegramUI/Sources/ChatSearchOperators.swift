import Foundation
import Postbox
import TelegramCore
import SwiftSignalKit
import AccountContext
import TelegramUIPreferences
import NanogramFeatures

// Search operators for the search field inside a chat. Grammar: docs/specs/search-operators.md.

final class ChatSearchOperatorSenders {
    enum Entry {
        case pending
        case resolved(PeerId)
        case unknown
    }

    private var entries: [String: Entry] = [:]
    private let disposables = DisposableSet()

    deinit {
        self.disposables.dispose()
    }

    // `from:` values are resolved one by one; `onChange` runs on the main queue when a lookup finishes.
    func entry(for name: String, context: AccountContext, onChange: @escaping () -> Void) -> Entry {
        let key = name.lowercased()
        if let entry = self.entries[key] {
            return entry
        }
        if key == "me" {
            let entry = Entry.resolved(context.account.peerId)
            self.entries[key] = entry
            return entry
        }
        // iOS resolves public usernames. A display name has nothing to resolve against, so it stays plain text.
        guard key.count >= 3, key.count <= 32, let first = key.unicodeScalars.first, CharacterSet.letters.contains(first), key.unicodeScalars.allSatisfy({ ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "_" }) else {
            self.entries[key] = .unknown
            return .unknown
        }
        self.entries[key] = .pending
        let disposable = (context.engine.peers.resolvePeerByName(name: key, referrer: nil)
        |> deliverOnMainQueue).startStrict(next: { [weak self] result in
            guard let self else {
                return
            }
            switch result {
            case .progress:
                break
            case let .result(peer):
                if let peer {
                    self.entries[key] = .resolved(peer.id)
                } else {
                    self.entries[key] = .unknown
                }
                onChange()
            }
        })
        self.disposables.add(disposable)
        return .pending
    }
}

struct ChatSearchOperatorsResult {
    var query: String
    var fromId: PeerId?
    var tags: MessageTags?
    var minDate: Int32?
    var maxDate: Int32?
}

private let supportedSearchOperatorTypes: [SearchOperatorType: MessageTags] = [
    .photo: .photo,
    .video: .video,
    .file: .file,
    .link: .webPage,
    .voice: .voice,
    .music: .music,
    .gif: .gif,
    .round: .roundVideo,
    .poll: .polls,
    .pinned: .pinned
]

extension ChatControllerImpl {
    // nil when the setting is off, the chat is secret, or the query holds no operator.
    func searchOperatorsResult(query: String, peerId: PeerId) -> ChatSearchOperatorsResult? {
        guard NanogramFeaturesSettings.current.with({ $0.searchOperators }), peerId.namespace != Namespaces.Peer.SecretChat else {
            return nil
        }
        let parsed = SearchOperators.parse(query, supportedTypes: Set(supportedSearchOperatorTypes.keys))
        guard parsed.hasOperators else {
            return nil
        }
        var result = ChatSearchOperatorsResult(query: parsed.text, fromId: nil, tags: parsed.type.flatMap { supportedSearchOperatorTypes[$0] }, minDate: parsed.minDate, maxDate: parsed.maxDate)
        if let fromName = parsed.fromName {
            let entry = self.searchOperatorSenders.entry(for: fromName, context: self.context, onChange: { [weak self] in
                self?.updateChatPresentationInterfaceState(animated: false, interactive: false, { $0 })
            })
            switch entry {
            case let .resolved(peerId):
                result.fromId = peerId
            case .pending:
                break
            case .unknown:
                result.query = parsed.textRestoringFrom()
            }
        }
        return result
    }
}
