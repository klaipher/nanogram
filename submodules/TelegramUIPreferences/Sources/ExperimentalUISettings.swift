import Foundation
import TelegramCore
import SwiftSignalKit

public struct ExperimentalUISettings: Codable, Equatable {
    public enum VideoMessageCameraMode: String, CaseIterable {
        case legacy
        case vga
        case hdBilinear
        case hdLanczos
    }

    /// Debug Settings ▸ "Circle Colour Decode". The YCbCr matrix the modern round-video pipeline (CameraNeo)
    /// decodes the camera's 8-bit 4:2:0 frames with. The camera tags them BT.601, but their colours match the
    /// camera's own BGRA conversion (what Legacy records, and what the official app shows) only when decoded as
    /// BT.709; decoding by the tag turned skin and lips ~7-9° towards magenta. `.cameraTag` is the old
    /// behaviour. A BT.2020 tag (10-bit/HDR formats) is followed whatever the choice. Read when the camera
    /// screen opens.
    public enum RoundVideoCameraMatrix: String, CaseIterable {
        case bt709
        case cameraTag
        case bt601
    }

    /// Debug Settings ▸ "Stickers: renderer". Which renderer an animated sticker node uses, together
    /// with the matching frame cache: today's CPU path, the Metal renderer for large stickers only, or
    /// the Metal renderer for every sticker node. Read when a node is created.
    public enum StickerRendererMode: String, CaseIterable {
        case cpu
        case gpuLarge
        case gpuAll
    }

    public var keepChatNavigationStack: Bool
    public var skipReadHistory: Bool
    public var alwaysDisplayTyping: Bool
    public var crashOnLongQueries: Bool
    public var enableVoipTcp: Bool
    public var fakeGlass: Bool
    public var compressedEmojiCache: Bool
    public var localTranscription: Bool
    public var disableQuickReaction: Bool
    public var disableLanguageRecognition: Bool
    public var disableImageContentAnalysis: Bool
    public var crashOnMemoryPressure: Bool
    // Group calls: use the PeerConnection-based GroupInstanceReferenceImpl instead of
    // GroupInstanceCustomImpl (the ios_calls_group_reference_impl app-config flag can
    // also turn it on; live streams always use the custom engine).
    public var groupCallReferenceEngine: Bool
    public var liveStreamV2: Bool
    public var autoBenchmarkReflectors: Bool?
    public var checkSerializedData: Bool
    public var useInputDecEngine: Bool
    /// Debug Settings ▸ "Chat: old list (ListViewImpl)". A device-local opt-out of CoreList for the chat history,
    /// which uses CoreList by default. Read when a chat's history list is created.
    public var forceListViewImplChatBackend: Bool
    public var forceRLottieBackend: Bool
    public var respectSystemMicrophone: Bool
    public var springSendAnimation: Bool
    /// Debug Settings ▸ "Wallet: fake transfers", offered to dev accounts only (and only honoured for them): a send
    /// from the transfer form sends nothing and closes as a registered transfer would, against a fixed balance.
    public var fakeWalletTransfers: Bool
    public var showCrashReportAlerts: Bool?
    public var useModernVideoMessagePipeline: Bool?
    public var videoMessageCameraMode: VideoMessageCameraMode
    /// Debug Settings ▸ "Circle Close Focus (Macro)". Off by default. The round-video camera (CameraNeo) opens
    /// the back camera as a virtual device with the ultra-wide, so iOS can switch to it for close subjects,
    /// with the 1x framing kept (`Camera.RoundVideoCloseFocus`). Read when the camera screen opens.
    public var videoMessageCloseFocus: Bool
    public var videoMessageCameraMatrix: RoundVideoCameraMatrix
    /// Debug Settings ▸ "iPad: Display Link 120 Hz Cap" (audit B-1, off by default): an iPad's shared display link
    /// follows the rate its animations ask for instead of always 120 Hz; toggling it starts a frame-pacing log.
    public var tabletDisplayLinkFrameRateCap: Bool
    /// Debug Settings ▸ "Calls: livestream hardware decoding". Off by default. Live stream video is decoded
    /// with VideoToolbox instead of FFmpeg's software decoders (at most 2 sessions, per-stream fallback to
    /// software on any error). Local only: nothing is negotiated or sent. Read when a call starts.
    public var callsLivestreamHardwareDecoding: Bool
    /// Debug Settings ▸ "Calls: native camera frames". Off by default. Camera frames reach the encoder as
    /// NV12 pixel buffers instead of being converted to I420 on the CPU first. Local only.
    public var callsNativeCapturePath: Bool
    /// Debug Settings ▸ "Calls: low-latency encoder". Off by default. The H.264 VideoToolbox encoder runs in
    /// real-time low-latency rate-control mode on iOS 14.5+, retrying without it if the session cannot be
    /// created. Local only.
    public var callsEncoderLowLatency: Bool
    public var stickerRendererMode: StickerRendererMode

    public static var defaultSettings: ExperimentalUISettings {
        return ExperimentalUISettings(
            keepChatNavigationStack: false,
            skipReadHistory: false,
            alwaysDisplayTyping: false,
            crashOnLongQueries: false,
            enableVoipTcp: false,
            fakeGlass: false,
            compressedEmojiCache: true,
            localTranscription: false,
            disableQuickReaction: false,
            disableLanguageRecognition: false,
            disableImageContentAnalysis: false,
            crashOnMemoryPressure: false,
            groupCallReferenceEngine: false,
            liveStreamV2: false,
            autoBenchmarkReflectors: nil,
            checkSerializedData: false,
            useInputDecEngine: false,
            forceListViewImplChatBackend: false,
            forceRLottieBackend: false,
            respectSystemMicrophone: false,
            springSendAnimation: false,
            fakeWalletTransfers: false,
            useModernVideoMessagePipeline: nil,
            showCrashReportAlerts: nil
        )
    }
    
    public init(
        keepChatNavigationStack: Bool,
        skipReadHistory: Bool,
        alwaysDisplayTyping: Bool,
        crashOnLongQueries: Bool,
        enableVoipTcp: Bool,
        fakeGlass: Bool,
        compressedEmojiCache: Bool,
        localTranscription: Bool,
        disableQuickReaction: Bool,
        disableLanguageRecognition: Bool,
        disableImageContentAnalysis: Bool,
        crashOnMemoryPressure: Bool,
        groupCallReferenceEngine: Bool,
        liveStreamV2: Bool,
        autoBenchmarkReflectors: Bool?,
        checkSerializedData: Bool,
        useInputDecEngine: Bool,
        forceListViewImplChatBackend: Bool,
        forceRLottieBackend: Bool,
        respectSystemMicrophone: Bool,
        springSendAnimation: Bool,
        fakeWalletTransfers: Bool,
        useModernVideoMessagePipeline: Bool? = nil,
        videoMessageCameraMode: VideoMessageCameraMode = .hdBilinear,
        stickerRendererMode: StickerRendererMode = .gpuLarge,
        showCrashReportAlerts: Bool? = nil,
        videoMessageCloseFocus: Bool = false,
        videoMessageCameraMatrix: RoundVideoCameraMatrix = .bt709,
        tabletDisplayLinkFrameRateCap: Bool = false,
        callsLivestreamHardwareDecoding: Bool = false,
        callsNativeCapturePath: Bool = false,
        callsEncoderLowLatency: Bool = false
    ) {
        self.keepChatNavigationStack = keepChatNavigationStack
        self.skipReadHistory = skipReadHistory
        self.alwaysDisplayTyping = alwaysDisplayTyping
        self.crashOnLongQueries = crashOnLongQueries
        self.enableVoipTcp = enableVoipTcp
        self.fakeGlass = fakeGlass
        self.compressedEmojiCache = compressedEmojiCache
        self.localTranscription = localTranscription
        self.disableQuickReaction = disableQuickReaction
        self.disableLanguageRecognition = disableLanguageRecognition
        self.disableImageContentAnalysis = disableImageContentAnalysis
        self.crashOnMemoryPressure = crashOnMemoryPressure
        self.groupCallReferenceEngine = groupCallReferenceEngine
        self.liveStreamV2 = liveStreamV2
        self.autoBenchmarkReflectors = autoBenchmarkReflectors
        self.checkSerializedData = checkSerializedData
        self.useInputDecEngine = useInputDecEngine
        self.forceListViewImplChatBackend = forceListViewImplChatBackend
        self.forceRLottieBackend = forceRLottieBackend
        self.respectSystemMicrophone = respectSystemMicrophone
        self.springSendAnimation = springSendAnimation
        self.fakeWalletTransfers = fakeWalletTransfers
        self.showCrashReportAlerts = showCrashReportAlerts
        self.useModernVideoMessagePipeline = useModernVideoMessagePipeline
        self.videoMessageCameraMode = videoMessageCameraMode
        self.videoMessageCloseFocus = videoMessageCloseFocus
        self.videoMessageCameraMatrix = videoMessageCameraMatrix
        self.stickerRendererMode = stickerRendererMode
        self.tabletDisplayLinkFrameRateCap = tabletDisplayLinkFrameRateCap
        self.callsLivestreamHardwareDecoding = callsLivestreamHardwareDecoding
        self.callsNativeCapturePath = callsNativeCapturePath
        self.callsEncoderLowLatency = callsEncoderLowLatency
    }
    
    /// Revision of Nanogram's defaults that a saved blob was written with. Revision 1 turned on large
    /// stickers on the Metal renderer and custom emoji on the YUVA path. Every save writes the current
    /// revision, so an older blob is upgraded once and a later choice is kept.
    static let nanogramDefaultsRevision: Int32 = 1

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StringCodingKey.self)
        let savedDefaultsRevision = try container.decodeIfPresent(Int32.self, forKey: "nanogramDefaultsRevision") ?? 0

        self.keepChatNavigationStack = (try container.decodeIfPresent(Int32.self, forKey: "keepChatNavigationStack") ?? 0) != 0
        self.skipReadHistory = (try container.decodeIfPresent(Int32.self, forKey: "skipReadHistory") ?? 0) != 0
        self.alwaysDisplayTyping = (try container.decodeIfPresent(Int32.self, forKey: "alwaysDisplayTyping") ?? 0) != 0
        self.crashOnLongQueries = (try container.decodeIfPresent(Int32.self, forKey: "crashOnLongQueries") ?? 0) != 0
        self.enableVoipTcp = (try container.decodeIfPresent(Int32.self, forKey: "enableVoipTcp") ?? 0) != 0
        self.fakeGlass = (try container.decodeIfPresent(Int32.self, forKey: "fakeGlass") ?? 0) != 0
        self.compressedEmojiCache = (try container.decodeIfPresent(Int32.self, forKey: "compressedEmojiCache") ?? 1) != 0
        self.localTranscription = (try container.decodeIfPresent(Int32.self, forKey: "localTranscription") ?? 0) != 0
        self.disableQuickReaction = try container.decodeIfPresent(Bool.self, forKey: "disableQuickReaction") ?? false
        self.disableLanguageRecognition = try container.decodeIfPresent(Bool.self, forKey: "disableLanguageRecognition") ?? false
        self.disableImageContentAnalysis = try container.decodeIfPresent(Bool.self, forKey: "disableImageContentAnalysis") ?? false
        self.crashOnMemoryPressure = try container.decodeIfPresent(Bool.self, forKey: "crashOnMemoryPressure") ?? false
        self.groupCallReferenceEngine = try container.decodeIfPresent(Bool.self, forKey: "groupCallReferenceEngine") ?? false
        self.liveStreamV2 = try container.decodeIfPresent(Bool.self, forKey: "liveStreamV2") ?? false
        self.autoBenchmarkReflectors = try container.decodeIfPresent(Bool.self, forKey: "autoBenchmarkReflectors")
        self.checkSerializedData = try container.decodeIfPresent(Bool.self, forKey: "checkSerializedData") ?? false
        // `?? false` like its neighbours: an existing settings blob predates this key, and a
        // decode failure here would reset every other experimental flag the user has set.
        self.useInputDecEngine = try container.decodeIfPresent(Bool.self, forKey: "useInputDecEngine") ?? false
        self.forceListViewImplChatBackend = try container.decodeIfPresent(Bool.self, forKey: "forceListViewImplChatBackend") ?? false
        self.forceRLottieBackend = try container.decodeIfPresent(Bool.self, forKey: "forceRLottieBackend") ?? false
        self.respectSystemMicrophone = try container.decodeIfPresent(Bool.self, forKey: "respectSystemMicrophone") ?? false
        self.springSendAnimation = try container.decodeIfPresent(Bool.self, forKey: "springSendAnimation") ?? false
        self.fakeWalletTransfers = try container.decodeIfPresent(Bool.self, forKey: "fakeWalletTransfers") ?? false
        self.showCrashReportAlerts = try container.decodeIfPresent(Bool.self, forKey: "showCrashReportAlerts")
        self.useModernVideoMessagePipeline = try container.decodeIfPresent(Bool.self, forKey: "useModernVideoMessagePipeline")
        self.videoMessageCameraMode = (try container.decodeIfPresent(String.self, forKey: "videoMessageCameraMode")).flatMap(VideoMessageCameraMode.init(rawValue:)) ?? .hdBilinear
        self.stickerRendererMode = (try container.decodeIfPresent(String.self, forKey: "stickerRendererMode")).flatMap(StickerRendererMode.init(rawValue:)) ?? .gpuLarge
        self.videoMessageCloseFocus = try container.decodeIfPresent(Bool.self, forKey: "videoMessageCloseFocus") ?? false
        // A new key: blobs saved before it existed (and unknown values) get the BT.709 default.
        self.videoMessageCameraMatrix = (try container.decodeIfPresent(String.self, forKey: "videoMessageCameraMatrix")).flatMap(RoundVideoCameraMatrix.init(rawValue:)) ?? .bt709
        self.tabletDisplayLinkFrameRateCap = try container.decodeIfPresent(Bool.self, forKey: "tabletDisplayLinkFrameRateCap") ?? false

        if savedDefaultsRevision < 1 {
        self.callsLivestreamHardwareDecoding = try container.decodeIfPresent(Bool.self, forKey: "callsLivestreamHardwareDecoding") ?? false
        self.callsNativeCapturePath = try container.decodeIfPresent(Bool.self, forKey: "callsNativeCapturePath") ?? false
        self.callsEncoderLowLatency = try container.decodeIfPresent(Bool.self, forKey: "callsEncoderLowLatency") ?? false
            // Saved before the GPU renderers became the default: both were the old CPU defaults.
            if self.stickerRendererMode == .cpu {
                self.stickerRendererMode = .gpuLarge
            }
            self.compressedEmojiCache = true
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StringCodingKey.self)

        try container.encode((self.keepChatNavigationStack ? 1 : 0) as Int32, forKey: "keepChatNavigationStack")
        try container.encode((self.skipReadHistory ? 1 : 0) as Int32, forKey: "skipReadHistory")
        try container.encode((self.alwaysDisplayTyping ? 1 : 0) as Int32, forKey: "alwaysDisplayTyping")
        try container.encode((self.crashOnLongQueries ? 1 : 0) as Int32, forKey: "crashOnLongQueries")
        try container.encode((self.enableVoipTcp ? 1 : 0) as Int32, forKey: "enableVoipTcp")
        try container.encode((self.fakeGlass ? 1 : 0) as Int32, forKey: "fakeGlass")
        try container.encode((self.compressedEmojiCache ? 1 : 0) as Int32, forKey: "compressedEmojiCache")
        try container.encode((self.localTranscription ? 1 : 0) as Int32, forKey: "localTranscription")
        try container.encode(self.disableQuickReaction, forKey: "disableQuickReaction")
        try container.encode(self.disableLanguageRecognition, forKey: "disableLanguageRecognition")
        try container.encode(self.disableImageContentAnalysis, forKey: "disableImageContentAnalysis")
        try container.encode(self.crashOnMemoryPressure, forKey: "crashOnMemoryPressure")
        try container.encode(self.groupCallReferenceEngine, forKey: "groupCallReferenceEngine")
        try container.encode(self.liveStreamV2, forKey: "liveStreamV2")
        try container.encodeIfPresent(self.autoBenchmarkReflectors, forKey: "autoBenchmarkReflectors")
        try container.encodeIfPresent(self.checkSerializedData, forKey: "checkSerializedData")
        try container.encodeIfPresent(self.useInputDecEngine, forKey: "useInputDecEngine")
        try container.encode(self.forceListViewImplChatBackend, forKey: "forceListViewImplChatBackend")
        try container.encodeIfPresent(self.forceRLottieBackend, forKey: "forceRLottieBackend")
        try container.encodeIfPresent(self.respectSystemMicrophone, forKey: "respectSystemMicrophone")
        try container.encodeIfPresent(self.springSendAnimation, forKey: "springSendAnimation")
        try container.encodeIfPresent(self.fakeWalletTransfers, forKey: "fakeWalletTransfers")
        try container.encodeIfPresent(self.showCrashReportAlerts, forKey: "showCrashReportAlerts")
        try container.encodeIfPresent(self.useModernVideoMessagePipeline, forKey: "useModernVideoMessagePipeline")
        try container.encode(self.videoMessageCameraMode.rawValue, forKey: "videoMessageCameraMode")
        try container.encode(self.stickerRendererMode.rawValue, forKey: "stickerRendererMode")
        try container.encode(self.videoMessageCloseFocus, forKey: "videoMessageCloseFocus")
        try container.encode(self.videoMessageCameraMatrix.rawValue, forKey: "videoMessageCameraMatrix")
        try container.encode(self.tabletDisplayLinkFrameRateCap, forKey: "tabletDisplayLinkFrameRateCap")
        try container.encode(ExperimentalUISettings.nanogramDefaultsRevision, forKey: "nanogramDefaultsRevision")
    }
        try container.encode(self.callsLivestreamHardwareDecoding, forKey: "callsLivestreamHardwareDecoding")
        try container.encode(self.callsNativeCapturePath, forKey: "callsNativeCapturePath")
        try container.encode(self.callsEncoderLowLatency, forKey: "callsEncoderLowLatency")
}

public func updateExperimentalUISettingsInteractively(accountManager: AccountManager<TelegramAccountManagerTypes>, _ f: @escaping (ExperimentalUISettings) -> ExperimentalUISettings) -> Signal<Void, NoError> {
    return accountManager.transaction { transaction -> Void in
        transaction.updateSharedData(ApplicationSpecificSharedDataKeys.experimentalUISettings, { entry in
            let currentSettings: ExperimentalUISettings
            if let entry = entry?.get(ExperimentalUISettings.self) {
                currentSettings = entry
            } else {
                currentSettings = .defaultSettings
            }
            return SharedPreferencesEntry(f(currentSettings))
        })
    }
}
