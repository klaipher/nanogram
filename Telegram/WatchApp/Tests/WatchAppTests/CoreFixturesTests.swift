// Shared fakes and fixtures for the Core*Tests (named to match the Core*Tests pattern).
import AVFoundation
import Foundation
import OpusKit
@preconcurrency import TDShim
@testable import tgwatch_Watch_App

/// History loader that records what the store asks TDLib for. Requests it does not script
/// fail, so a test notices an unexpected call.
actor CoreFakeHistoryLoader: ChatHistoryLoader {
    private(set) var viewed: [[Int64]] = []
    private(set) var downloads: [(fileId: Int, priority: Int)] = []
    private(set) var cancelledDownloads: [Int] = []
    private(set) var historyRequests: [(from: Int64, offset: Int, limit: Int)] = []
    var historyResult: Result<[Message], Error> = .success([])

    func setHistoryResult(_ result: Result<[Message], Error>) { historyResult = result }

    func openChat(chatId: Int64) async throws {}
    func closeChat(chatId: Int64) async throws {}
    func loadHistory(chatId: Int64, fromMessageId: Int64, offset: Int, limit: Int) async throws -> [Message] {
        historyRequests.append((fromMessageId, offset, limit))
        return try historyResult.get()
    }
    func downloadFile(fileId: Int, priority: Int) async throws -> File {
        downloads.append((fileId, priority))
        throw CancellationError()
    }
    func cancelDownloadFile(fileId: Int) async throws { cancelledDownloads.append(fileId) }
    func sendText(chatId: Int64, text: String) async throws -> Message { throw CancellationError() }
    func sendVoiceNote(chatId: Int64, fileURL: URL, duration: Int, waveform: Data) async throws -> Message {
        throw CancellationError()
    }
    func setChatDraftMessage(chatId: Int64, draftText: String) async throws {}
    func viewMessages(chatId: Int64, messageIds: [Int64], forceRead: Bool) async throws {
        viewed.append(messageIds)
    }
    func setPollAnswer(chatId: Int64, messageId: Int64, optionIds: [Int]) async throws {}
    func sendSticker(chatId: Int64, remoteFileId: String, emoji: String, width: Int, height: Int) async throws -> Message {
        throw CancellationError()
    }
    func sendLocation(chatId: Int64, latitude: Double, longitude: Double) async throws -> Message {
        throw CancellationError()
    }
}

@MainActor
final class CoreFakeVoiceBackend: VoicePlaybackBackend {
    private(set) var releaseCount = 0
    private(set) var completion: (@MainActor () -> Void)?
    var elapsed: Double = 0
    var lastBufferDuration: Double = 1

    func prepare() throws {}
    func play(buffer: AVAudioPCMBuffer, completion: @escaping @MainActor () -> Void) throws {
        self.completion = completion
    }
    func pause() {}
    func resume() {}
    func stop() {}
    func releaseHardware() { releaseCount += 1 }
}

struct CoreFakeVoiceDecoder: VoiceDecoder {
    func decodePCM(url: URL) async throws -> DecodedOpus {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
        buffer.frameLength = 480
        return DecodedOpus(pcm: buffer)
    }
}

@MainActor
final class CoreFakeAudioBackend: AudioPlayerBackend {
    var onProgress: ((Double) -> Void)?
    var onEnded: (() -> Void)?
    var onFailed: ((String) -> Void)?
    var elapsed: Double = 0
    func load(url: URL) throws {}
    func play() {}
    func pause() {}
    func stop() {}
}

enum CoreFixtures {
    static let chatId: Int64 = 1

    /// The decoder TDLibApi uses for every response.
    static func tdlibDecoder() -> JSONDecoder {
        JSONDecoder()
    }

    /// A plain incoming text message as TDLib 1.8.64 sends it.
    static func messageJSON(id: Int64, text: String = "hi", outgoing: Bool = false) -> String {
        """
        {"@type":"message","id":\(id),"sender_id":{"@type":"messageSenderUser","user_id":2},
         "chat_id":\(chatId),"is_outgoing":\(outgoing),"is_pinned":false,"is_from_offline":false,
         "can_be_saved":true,"has_timestamped_media":false,"is_channel_post":false,
         "is_paid_star_suggested_post":false,"is_paid_ton_suggested_post":false,
         "contains_unread_mention":false,"contains_unread_poll_votes":false,
         "date":1700000000,"edit_date":0,"unread_reactions":[],"via_bot_user_id":0,
         "sender_business_bot_user_id":0,"sender_boost_count":0,"paid_message_star_count":0,
         "author_signature":"","media_album_id":"0","effect_id":"0","self_destruct_in":0,
         "auto_delete_in":0,"sender_tag":"","summary_language_code":"",
         "content":{"@type":"messageText","text":{"@type":"formattedText","text":"\(text)","entities":[]}}}
        """
    }

    static func message(id: Int64, outgoing: Bool = false) throws -> Message {
        try tdlibDecoder().decode(Message.self, from: Data(messageJSON(id: id, outgoing: outgoing).utf8))
    }

    @MainActor
    static func historyStore(loader: CoreFakeHistoryLoader) -> ChatHistoryStore {
        ChatHistoryStore(
            chatId: chatId,
            chatType: .chatTypePrivate(ChatTypePrivate(userId: 2)),
            lastReadInboxMessageId: 0,
            unreadCount: 0,
            lastMessageId: nil,
            loader: loader,
            voicePlayback: VoicePlaybackController(backend: CoreFakeVoiceBackend(), decoder: CoreFakeVoiceDecoder()),
            audioPlayback: AudioPlaybackController(backend: CoreFakeAudioBackend())
        )
    }
}

/// Polls `condition` on the main actor until it holds or `timeout` passes.
@MainActor
func coreWait(timeout: TimeInterval = 2, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return await condition()
}
