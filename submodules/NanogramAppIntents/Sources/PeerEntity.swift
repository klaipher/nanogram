import AppIntents
import Foundation
import NanogramGlance

@available(iOS 16.0, *)
public struct PeerEntity: AppEntity {
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Chat")
    public static let defaultQuery = PeerEntityQuery()

    public var id: String
    public var title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }

    public init(_ peer: GlancePeerRef) {
        self.id = peer.identifier
        self.title = peer.title
    }

    public var displayRepresentation: DisplayRepresentation {
        return DisplayRepresentation(title: "\(self.title)")
    }
}

/// Suggestions and search come from the snapshot the app writes in the app group. It holds no chats while the app is
/// passcode-locked or the feature is off, so the picker is empty then. A stored identifier always resolves (the
/// snapshot title when listed, a generic one otherwise), so a configured widget or a saved shortcut survives the
/// chat leaving the top chats and the passcode lock.
@available(iOS 16.0, *)
public struct PeerEntityQuery: EntityStringQuery {
    public static let genericTitle = "Chat"

    public init() {
    }

    private func candidates() -> [GlancePeerRef] {
        return GlanceEntityResolver.candidates(snapshot: NanogramIntentEnvironment.snapshotReader())
    }

    public func entities(for identifiers: [String]) async throws -> [PeerEntity] {
        return GlanceEntityResolver.resolve(identifiers: identifiers, snapshot: NanogramIntentEnvironment.snapshotReader(), genericTitle: PeerEntityQuery.genericTitle).map(PeerEntity.init)
    }

    public func entities(matching string: String) async throws -> [PeerEntity] {
        let needle = string.lowercased()
        return self.candidates().filter { $0.title.lowercased().contains(needle) }.map(PeerEntity.init)
    }

    public func suggestedEntities() async throws -> [PeerEntity] {
        return self.candidates().map(PeerEntity.init)
    }
}
