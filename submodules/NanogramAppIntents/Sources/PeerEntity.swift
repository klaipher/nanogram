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

/// Candidates come from the snapshot the app writes in the app group. It holds no chats while the app is
/// passcode-locked or the feature is off, so the picker is empty then.
@available(iOS 16.0, *)
public struct PeerEntityQuery: EntityStringQuery {
    public init() {
    }

    private func peers() -> [GlancePeerRef] {
        guard let rootPath = GlanceLocation.rootPath(), let snapshot = GlanceStore.read(rootPath: rootPath), snapshot.enabled else {
            return []
        }
        return snapshot.peers
    }

    public func entities(for identifiers: [String]) async throws -> [PeerEntity] {
        let wanted = Set(identifiers)
        return self.peers().filter { wanted.contains($0.identifier) }.map(PeerEntity.init)
    }

    public func entities(matching string: String) async throws -> [PeerEntity] {
        let needle = string.lowercased()
        return self.peers().filter { $0.title.lowercased().contains(needle) }.map(PeerEntity.init)
    }

    public func suggestedEntities() async throws -> [PeerEntity] {
        return self.peers().map(PeerEntity.init)
    }
}
