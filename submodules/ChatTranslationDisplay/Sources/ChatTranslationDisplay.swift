/// The per-chat translation state as `chatTranslationState` (TranslateUI) reports it: the language
/// detected in the recent messages, the chosen target language, and whether translation is on
/// (the user's choice, or on by default in a channel with autotranslation).
public struct ChatTranslationDetectedState: Equatable, Sendable {
    public let fromLang: String
    public let toLang: String?
    public let isEnabled: Bool

    public init(fromLang: String, toLang: String?, isEnabled: Bool) {
        self.fromLang = fromLang
        self.toLang = toLang
        self.isEnabled = isEnabled
    }
}

/// What the chat's translation bar shows. `isEnabled` means the messages are shown translated and
/// the bar offers "Show Original".
public struct ChatTranslationDisplay: Equatable, Sendable {
    public let isEnabled: Bool
    public let fromLang: String
    public let toLang: String

    public init(isEnabled: Bool, fromLang: String, toLang: String) {
        self.isEnabled = isEnabled
        self.fromLang = fromLang
        self.toLang = toLang
    }
}

public struct ChatTranslationResolution: Sendable {
    /// The translation bar, or nil when the chat shows none.
    public let bar: ChatTranslationDisplay?
    /// The languages the message list translates between, or nil when it shows the originals.
    /// Never set without a `bar` whose `isEnabled` is true.
    public let messageLanguages: (fromLang: String, toLang: String)?
}

/// One decision for both halves of chat translation: the bar (ChatControllerContentData) and the
/// message list (ChatHistoryListNode).
///
/// Upstream decided them separately, and the list ignored two things the bar honoured: the bar
/// being hidden (`translationHidden`, set by the bar's X or "Hide" on any device and synced by
/// the server) and an undetected source language. In a channel with autotranslation, where
/// translation is on by default, that left messages translated with no "Show Original" anywhere
/// in the chat. The list now translates only from the bar's own state.
public enum ChatTranslationDisplayPolicy {
    /// - Parameters:
    ///   - isHidden: the peer's `translationHidden` flag.
    ///   - isOffered: whether the chat may show the bar at all (Premium, channel autotranslation,
    ///     or the Premium suggestion).
    ///   - canTranslateMessages: whether messages may be translated (Premium or channel autotranslation).
    ///   - baseLanguageCode: the app language, already normalized ("en", not "en-raw").
    public static func resolve(state: ChatTranslationDetectedState?, isHidden: Bool, isOffered: Bool, canTranslateMessages: Bool, baseLanguageCode: String) -> ChatTranslationResolution {
        var bar: ChatTranslationDisplay?
        if isOffered && !isHidden, let state, !state.fromLang.isEmpty && (state.fromLang != baseLanguageCode || state.isEnabled) {
            bar = ChatTranslationDisplay(isEnabled: state.isEnabled, fromLang: state.fromLang, toLang: state.toLang ?? baseLanguageCode)
        }
        var messageLanguages: (fromLang: String, toLang: String)?
        if let bar, bar.isEnabled && canTranslateMessages {
            messageLanguages = (bar.fromLang, bar.toLang)
        }
        return ChatTranslationResolution(bar: bar, messageLanguages: messageLanguages)
    }
}

extension ChatTranslationDisplayPolicy {
    /// The languages a view of the chat's messages translates between: the message list
    /// (ChatHistoryListNode) and every view that shows the same messages outside it, such as the
    /// media viewer's caption (GalleryUI, via TranslateUI's `chatMessageTranslationLanguages`).
    /// Nil means the originals.
    ///
    /// The same answer as `resolve(...).messageLanguages` for the list, so a message is never
    /// shown translated in one place and original in another: the bar must be on screen offering
    /// "Show Original" (not hidden, a detected language, translation on), and the viewer must be
    /// allowed to translate (Premium, or the channel's autotranslation).
    ///
    /// - Parameters:
    ///   - isHidden: the peer's `translationHidden` flag.
    ///   - isPremium: the account's Premium status.
    ///   - hasAutoTranslate: the channel's autotranslation flag.
    ///   - baseLanguageCode: the app language, already normalized ("en", not "en-raw").
    public static func messageLanguages(state: ChatTranslationDetectedState?, isHidden: Bool, isPremium: Bool, hasAutoTranslate: Bool, baseLanguageCode: String) -> (fromLang: String, toLang: String)? {
        let canTranslateMessages = isPremium || hasAutoTranslate
        return self.resolve(state: state, isHidden: isHidden, isOffered: canTranslateMessages, canTranslateMessages: canTranslateMessages, baseLanguageCode: baseLanguageCode).messageLanguages
    }
}
