import Foundation
import OSLog
@preconcurrency import TDShim

/// Single seam between `ChatHistoryStore` and TDLib. Tests inject a fake; production
/// uses `TDLibChatHistoryLoader`.
///
/// `openChat` / `closeChat` notify TDLib that the chat is being viewed, which is required
/// for supergroup / channel updates to flow. `loadHistory` returns messages in reverse
/// chronological order (TDLib's contract); the store sorts ascending for display.
///
/// `downloadFile` / `cancelDownloadFile` drive viewport-based photo downloading. Both are
/// idempotent: TDLib short-circuits if the file is already on disk (download) or already
/// complete (cancel).
protocol ChatHistoryLoader: Sendable {
    func openChat(chatId: Int64) async throws
    func closeChat(chatId: Int64) async throws
    /// `offset`: pass 0 for "messages strictly older than fromMessageId" (default
    /// pagination call). Pass a negative N to additionally include N messages
    /// NEWER than fromMessageId — used for the open-at-unread anchor fetch and
    /// for newer-direction pagination. Mirrors TDLib's `getChatHistory` semantics.
    func loadHistory(chatId: Int64, fromMessageId: Int64, offset: Int, limit: Int) async throws -> [Message]
    func downloadFile(fileId: Int, priority: Int) async throws -> File
    func cancelDownloadFile(fileId: Int) async throws
    func sendText(chatId: Int64, text: String) async throws -> Message
    func sendVoiceNote(chatId: Int64, fileURL: URL, duration: Int, waveform: Data) async throws -> Message
    func setChatDraftMessage(chatId: Int64, draftText: String) async throws
    /// Marks the given message ids as viewed (read). `forceRead: false` matches
    /// the "user is currently looking at the chat" semantics — TDLib uses the
    /// `openChat` state to decide whether to actually mark read.
    func viewMessages(chatId: Int64, messageIds: [Int64], forceRead: Bool) async throws
    /// Casts (or changes) the current user's answer to a poll. `optionIds` are
    /// 0-based option positions; multiple ids only when the poll allows it.
    func setPollAnswer(chatId: Int64, messageId: Int64, optionIds: [Int]) async throws
    /// Sends an installed sticker by its remote file id (`InputFileRemote`).
    /// No local download is required — TDLib resolves the remote reference.
    func sendSticker(chatId: Int64, remoteFileId: String, emoji: String, width: Int, height: Int) async throws -> Message
    /// Sends the given coordinate as a static location message (`livePeriod` 0).
    func sendLocation(chatId: Int64, latitude: Double, longitude: Double) async throws -> Message
}

struct TDLibChatHistoryLoader: ChatHistoryLoader {
    let client: TDLibClient

    func openChat(chatId: Int64) async throws {
        _ = try await client.openChat(chatId: chatId)
    }

    func closeChat(chatId: Int64) async throws {
        _ = try await client.closeChat(chatId: chatId)
    }

    func loadHistory(chatId: Int64, fromMessageId: Int64, offset: Int, limit: Int) async throws -> [Message] {
        // Resilient path: skip the atomic `client.getChatHistory(...)` decode (which
        // throws on the first message TDLibKit can't model) and decode messages
        // one-by-one, dropping any that fail. TDLib evolves faster than the pinned
        // TDLibKit version, so some chats contain message types (e.g. `messageGift`
        // with a `gift.background` that TDLibKit expects but the server no longer
        // provides) that would otherwise break the entire chat load.
        try await loadHistoryResilient(
            chatId: chatId,
            fromMessageId: fromMessageId,
            offset: offset,
            limit: limit
        )
    }

    private func loadHistoryResilient(
        chatId: Int64,
        fromMessageId: Int64,
        offset: Int,
        limit: Int
    ) async throws -> [Message] {
        let query = GetChatHistory(
            chatId: chatId,
            fromMessageId: fromMessageId,
            limit: limit,
            offset: offset,
            onlyLocal: false
        )
        let dto = DTO(query, encoder: client.encoder)
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            do {
                try client.send(query: dto) { responseData in
                    continuation.resume(returning: responseData)
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
        return try Self.decodeMessagesLeniently(data, chatId: chatId, decoder: client.decoder)
    }

    /// An error response throws: returning no messages would read as "no more history",
    /// ending pagination for good and showing an empty chat instead of Retry.
    ///
    /// One decoding pass over the response. A message the models cannot decode (TDLib evolves
    /// faster than the pinned schema) is skipped on its own instead of failing the page.
    static func decodeMessagesLeniently(_ data: Data, chatId: Int64, decoder: JSONDecoder) throws -> [Message] {
        let logger = Logger(watchCategory: "chathistory")
        let response: HistoryResponse
        do {
            response = try decoder.decode(HistoryResponse.self, from: data)
        } catch {
            logger.warning("getChatHistory chatId=\(chatId, privacy: .public) — response was not JSON object")
            throw TDError(code: 500, message: "Malformed getChatHistory response")
        }
        if response.type == "error" {
            let code = response.code ?? 500
            let message = response.message ?? ""
            logger.warning("getChatHistory chatId=\(chatId, privacy: .public) failed: \(code, privacy: .public) \(message, privacy: .public)")
            throw TDError(code: code, message: message)
        }
        var decoded: [Message] = []
        decoded.reserveCapacity(response.messages.count)
        for (idx, entry) in response.messages.enumerated() {
            switch entry.result {
            case .success(let message):
                decoded.append(message)
            case .failure(let error):
                logger.warning("getChatHistory chatId=\(chatId, privacy: .public) — skipping message index=\(idx, privacy: .public) due to decode error: \(String(describing: error), privacy: .private)")
            }
        }
        return decoded
    }

    /// `messages`, or an `error`. Every field is optional so that either shape decodes.
    private struct HistoryResponse: Decodable {
        let type: String?
        let code: Int?
        let message: String?
        let messages: [LenientMessage]

        enum CodingKeys: String, CodingKey {
            case type = "@type"
            case code, message, messages
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try? container.decodeIfPresent(String.self, forKey: .type)
            code = try? container.decodeIfPresent(Int.self, forKey: .code)
            message = try? container.decodeIfPresent(String.self, forKey: .message)
            messages = (try? container.decodeIfPresent([LenientMessage].self, forKey: .messages)) ?? []
        }
    }

    private struct LenientMessage: Decodable {
        let result: Result<Message, Error>

        init(from decoder: Decoder) throws {
            result = Result { try Message(from: decoder) }
        }
    }

    func downloadFile(fileId: Int, priority: Int) async throws -> File {
        // synchronous=false → TDLib returns immediately and streams progress via updateFile.
        try await client.downloadFile(
            fileId: fileId,
            limit: 0,
            offset: 0,
            priority: priority,
            synchronous: false
        )
    }

    func cancelDownloadFile(fileId: Int) async throws {
        // onlyIfPending=false → cancel even if active.
        _ = try await client.cancelDownloadFile(fileId: fileId, onlyIfPending: false)
    }

    func sendText(chatId: Int64, text: String) async throws -> Message {
        try await client.sendMessage(
            chatId: chatId,
            inputMessageContent: .inputMessageText(InputMessageText(
                clearDraft: true,
                linkPreviewOptions: nil,
                text: FormattedText(entities: [], text: text)
            )),
            options: nil,
            replyMarkup: nil,
            replyTo: nil,
            topicId: nil
        )
    }

    func sendVoiceNote(chatId: Int64, fileURL: URL, duration: Int, waveform: Data) async throws -> Message {
        try await client.sendMessage(
            chatId: chatId,
            inputMessageContent: .inputMessageVoiceNote(InputMessageVoiceNote(
                caption: nil,
                duration: duration,
                selfDestructType: nil,
                voiceNote: .inputFileLocal(InputFileLocal(path: fileURL.path)),
                waveform: waveform
            )),
            options: nil,
            replyMarkup: nil,
            replyTo: nil,
            topicId: nil
        )
    }

    func setChatDraftMessage(chatId: Int64, draftText: String) async throws {
        let draft: DraftMessage? = draftText.isEmpty ? nil : DraftMessage(
            date: Int(Foundation.Date().timeIntervalSince1970),
            effectId: 0,
            inputMessageText: .inputMessageText(InputMessageText(
                clearDraft: false,
                linkPreviewOptions: nil,
                text: FormattedText(entities: [], text: draftText)
            )),
            replyTo: nil,
            suggestedPostInfo: nil
        )
        _ = try await client.setChatDraftMessage(
            chatId: chatId,
            draftMessage: draft,
            topicId: nil
        )
    }

    func viewMessages(chatId: Int64, messageIds: [Int64], forceRead: Bool) async throws {
        _ = try await client.viewMessages(
            chatId: chatId,
            forceRead: forceRead,
            messageIds: messageIds,
            source: nil
        )
    }

    func setPollAnswer(chatId: Int64, messageId: Int64, optionIds: [Int]) async throws {
        _ = try await client.setPollAnswer(chatId: chatId, messageId: messageId, optionIds: optionIds)
    }

    func sendSticker(chatId: Int64, remoteFileId: String, emoji: String, width: Int, height: Int) async throws -> Message {
        try await client.sendMessage(
            chatId: chatId,
            inputMessageContent: .inputMessageSticker(InputMessageSticker(
                emoji: emoji,
                height: height,
                sticker: .inputFileRemote(InputFileRemote(id: remoteFileId)),
                thumbnail: nil,
                width: width
            )),
            options: nil,
            replyMarkup: nil,
            replyTo: nil,
            topicId: nil
        )
    }

    func sendLocation(chatId: Int64, latitude: Double, longitude: Double) async throws -> Message {
        try await client.sendMessage(
            chatId: chatId,
            inputMessageContent: .inputMessageLocation(InputMessageLocation(
                heading: 0,
                livePeriod: 0,
                location: Location(horizontalAccuracy: 0, latitude: latitude, longitude: longitude),
                proximityAlertRadius: 0
            )),
            options: nil,
            replyMarkup: nil,
            replyTo: nil,
            topicId: nil
        )
    }
}
