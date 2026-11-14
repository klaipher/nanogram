import AppIntents

/// Configuration of the Home Screen and Lock Screen chats widget. The identifiers are the "<accountId>:<peerId>"
/// the SiriKit widgets use, so the widget reads the chats through the same path.
@available(iOS 17.0, *)
public struct SelectChatsIntent: WidgetConfigurationIntent {
    public static let title: LocalizedStringResource = "Select Chats"
    public static let description = IntentDescription("Choose the chats this widget follows.")

    @Parameter(title: "Chats")
    public var chats: [PeerEntity]?

    public init() {
    }

    public init(chats: [PeerEntity]?) {
        self.chats = chats
    }
}
