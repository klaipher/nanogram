import AppIntents
import Foundation
import NanogramGlance

@available(iOS 16.0, *)
public enum NanogramIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notEnabled
    case notReady
    case locked
    case failed

    public var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notEnabled:
            return "Shortcuts are switched off in Nanogram's Debug settings."
        case .notReady:
            return "Open Nanogram once, then try again."
        case .locked:
            return "Unlock Nanogram first."
        case .failed:
            return "Nanogram could not do that."
        }
    }
}

private func currentSnapshot() -> GlanceSnapshot? {
    guard let rootPath = GlanceLocation.rootPath() else {
        return nil
    }
    return GlanceStore.read(rootPath: rootPath)
}

@available(iOS 16.0, *)
public struct OpenChatIntent: AppIntent {
    public static let title: LocalizedStringResource = "Open Chat"
    public static let description = IntentDescription("Opens a chat in Nanogram.")
    public static let openAppWhenRun = true

    @Parameter(title: "Chat")
    public var chat: PeerEntity

    public init() {
    }

    public init(chat: PeerEntity) {
        self.chat = chat
    }

    public static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$chat)")
    }

    public func perform() async throws -> some IntentResult {
        guard let snapshot = currentSnapshot(), snapshot.enabled else {
            throw NanogramIntentError.notEnabled
        }
        guard let target = GlanceIdentifier.parse(self.chat.id) else {
            throw NanogramIntentError.failed
        }
        guard let handler = await GlanceIntentBridge.shared.waitForHandler(timeout: 8.0) else {
            throw NanogramIntentError.notReady
        }
        guard await handler.openChat(target.accountId, target.peerId) else {
            throw NanogramIntentError.failed
        }
        return .result()
    }
}

@available(iOS 16.0, *)
public struct OpenSavedMessagesIntent: AppIntent {
    public static let title: LocalizedStringResource = "Open Saved Messages"
    public static let description = IntentDescription("Opens Saved Messages in Nanogram.")
    public static let openAppWhenRun = true

    public init() {
    }

    public func perform() async throws -> some IntentResult {
        guard let snapshot = currentSnapshot(), snapshot.enabled else {
            throw NanogramIntentError.notEnabled
        }
        guard let saved = snapshot.savedMessages ?? snapshot.peers.first(where: { $0.isSavedMessages }) else {
            throw NanogramIntentError.notReady
        }
        guard let handler = await GlanceIntentBridge.shared.waitForHandler(timeout: 8.0) else {
            throw NanogramIntentError.notReady
        }
        guard await handler.openChat(saved.accountId, saved.peerId) else {
            throw NanogramIntentError.failed
        }
        return .result()
    }
}

/// Runs in the app without opening it. Refused while the app is passcode-locked: the text is written into the
/// account, which a locked app must not accept from outside.
@available(iOS 16.0, *)
public struct SendToSavedMessagesIntent: AppIntent {
    public static let title: LocalizedStringResource = "Send to Saved Messages"
    public static let description = IntentDescription("Saves a note in your Saved Messages.")
    public static let openAppWhenRun = false

    @Parameter(title: "Text")
    public var text: String

    public init() {
    }

    public init(text: String) {
        self.text = text
    }

    public static var parameterSummary: some ParameterSummary {
        Summary("Send \(\.$text) to Saved Messages")
    }

    public func perform() async throws -> some IntentResult {
        guard let snapshot = currentSnapshot(), snapshot.enabled else {
            throw NanogramIntentError.notEnabled
        }
        let trimmed = self.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw NanogramIntentError.failed
        }
        guard let handler = await GlanceIntentBridge.shared.waitForHandler(timeout: 8.0) else {
            throw NanogramIntentError.notReady
        }
        switch await handler.sendToSavedMessages(snapshot.savedMessages?.accountId, trimmed) {
        case .queued:
            return .result()
        case .locked:
            throw NanogramIntentError.locked
        case .unavailable:
            throw NanogramIntentError.notReady
        }
    }
}

@available(iOS 16.0, *)
public struct NanogramShortcuts: AppShortcutsProvider {
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SendToSavedMessagesIntent(),
            phrases: [
                "Save a note in \(.applicationName)",
                "Send to Saved Messages in \(.applicationName)"
            ],
            shortTitle: "Saved Messages note",
            systemImageName: "bookmark"
        )
        AppShortcut(
            intent: OpenSavedMessagesIntent(),
            phrases: [
                "Open Saved Messages in \(.applicationName)"
            ],
            shortTitle: "Open Saved Messages",
            systemImageName: "bookmark.fill"
        )
        AppShortcut(
            intent: OpenChatIntent(),
            phrases: [
                "Open \(\.$chat) in \(.applicationName)"
            ],
            shortTitle: "Open chat",
            systemImageName: "bubble.left"
        )
    }
}
