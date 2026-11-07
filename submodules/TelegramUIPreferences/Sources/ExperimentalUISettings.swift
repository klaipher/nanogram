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
    public var coreListScrollTrace: Bool
    public var chatMediaEditorLegacy: Bool
    public var mediaGridLegacy: Bool
    public var sharedMediaGridLegacy: Bool
    public var storyLegacyVideoWriter: Bool
    public var chatLegacyVideoWriter: Bool
    public var chatSideListLegacy: Bool
    public var respectSystemMicrophone: Bool
    public var springSendAnimation: Bool
    /// Debug Settings ▸ "Wallet: fake transfers", offered to dev accounts only (and only honoured for them): a send
    /// from the transfer form sends nothing and closes as a registered transfer would, against a fixed balance.
    public var fakeWalletTransfers: Bool
    public var showCrashReportAlerts: Bool?
    public var useModernVideoMessagePipeline: Bool?
    public var videoMessageCameraMode: VideoMessageCameraMode
    /// Debug Settings ▸ "Circle Close Focus (Macro)". On by default. The round-video camera (CameraNeo) opens
    /// the back camera as a virtual device with the ultra-wide, so iOS can switch to it for close subjects,
    /// with the 1x framing kept (`Camera.RoundVideoCloseFocus`). Read when the camera screen opens.
    public var videoMessageCloseFocus: Bool
    public var videoMessageCameraMatrix: RoundVideoCameraMatrix
    /// Debug Settings ▸ "iPad: Display Link 120 Hz Cap" (audit B-1, off by default): an iPad's shared display link
    /// follows the rate its animations ask for instead of always 120 Hz; toggling it starts a frame-pacing log.
    public var tabletDisplayLinkFrameRateCap: Bool
    /// Debug Settings ▸ "List scroll (A/B vs Telegram)" ▸ "Display link: Telegram's rate". Off by default: the shared
    /// display link asks only for the rate its animations need (60 or 30 Hz). On: upstream's rule. Applies at once.
    public var displayLinkUpstreamRate: Bool
    /// Debug Settings ▸ "List scroll (A/B vs Telegram)" ▸ "List rows: accessibility text at once". Off by default: row
    /// accessibility strings are built after rows stop arriving. On: inside each row's layout, as upstream. Applies at once.
    public var listAccessibilityImmediate: Bool
    /// Debug Settings ▸ "List scroll (A/B vs Telegram)" ▸ "List scroll: log frame rate". Off by default. One log line per
    /// scroll gesture of any list (ListView): frames, average Hz, late frames.
    public var listScrollPacingLog: Bool
    /// Debug Settings ▸ "Calls: livestream hardware decoding". On by default (owner decision, 2026-11). Live stream video is decoded
    /// with VideoToolbox instead of FFmpeg's software decoders (at most 2 sessions, per-stream fallback to
    /// software on any error). Local only: nothing is negotiated or sent. Read when a call starts.
    public var callsLivestreamHardwareDecoding: Bool
    /// Debug Settings ▸ "Calls: native camera frames". On by default (owner decision, 2026-11). Camera frames reach the encoder as
    /// NV12 pixel buffers instead of being converted to I420 on the CPU first. Local only.
    public var callsNativeCapturePath: Bool
    /// Debug Settings ▸ "Calls: system noise suppression". On by default (owner decision, 2026-11). On iOS the call's microphone
    /// signal comes from the system voice-processing unit, which already suppresses noise; with this on,
    /// WebRTC's own noise suppression and high-pass filter are dropped from the outgoing audio instead of
    /// running a second time. Kept whenever the system unit is not in use. Local only.
    public var callsSystemNoiseSuppression: Bool
    /// Debug Settings ▸ "Calls: advanced ducking". Off by default (no device evidence yet). iOS 17+: the voice-processing unit lowers
    /// other audio only while someone speaks and by the smallest amount. Local audio-unit setting.
    public var callsAdvancedDucking: Bool
    /// Debug Settings ▸ "Streams & Calls" ▸ "Group noise suppression". 0 runs WebRTC's suppressor and
    /// RNNoise, 1 only WebRTC's, 2 (default, owner decision 2026-11) only RNNoise. Local only; applies from the next group call.
    public var callsGroupNoiseMode: Int32
    /// Debug Settings ▸ "Calls: thermal video ladder". On by default (owner decision, 2026-11). While the device is hot or in Low Power
    /// Mode the camera picture handed to the encoder gets smaller and slower (a local output-format request;
    /// nothing is negotiated). Applies from the next level change.
    public var callsThermalVideoLadder: Bool
    /// Debug Settings ▸ "Glass groups": bits of the chat glass groups that are replaced by their solid fallback, to attribute
    /// GPU passes to one group per recording. 0 (default) leaves all glass as it is. The bits are `glassDebugNavigationBar`,
    /// `glassDebugInputPanel`, `glassDebugFloatingButtons`; they equal `GlassDebugGroup`'s raw values.
    public var glassDebugDisabledGroups: Int32
    public static let glassDebugNavigationBar: Int32 = 1
    public static let glassDebugInputPanel: Int32 = 2
    public static let glassDebugFloatingButtons: Int32 = 4
    /// Debug Settings ▸ "Emoji panel: defer first-responder handoff / heavy layers". Off by default; main app only.
    /// On: opening the emoji / sticker / GIF panel builds the panel before the keyboard's input view and first responder change,
    /// and creates GIF tile display layers after the pane is on screen, a few per run-loop turn. Applies at once.
    public var emojiPanelDefersHeavyWork: Bool
    /// Debug Settings ▸ "Chat open: defer non-visible setup". Off by default. When on, a standard chat starts the subscriptions and
    /// helpers that are not needed for its first frame (send-as list, account colour, recorders, activity, panels context,
    /// translation host, network-speed notices) after its first appearance instead of inside `ChatControllerImpl.init`.
    /// Read once per chat controller (the value is cached in the controller).
    public var chatOpenDeferSetup: Bool
    /// Debug Settings ▸ "Chat scroll": bits of the chat-scroll switches that are on. 0 (default) leaves chat scrolling exactly
    /// as it is. The bits equal `ChatScrollExperiment`'s raw values (ChatRowPrep).
    public var chatScrollExperiments: Int32
    /// "Chat rows: prepare layout ahead".
    public static let chatScrollPrepareLayoutAhead: Int32 = 1
    /// "Chat rows: reuse row views".
    public static let chatScrollReuseRowViews: Int32 = 2
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
            coreListScrollTrace: false,
            chatMediaEditorLegacy: false,
            mediaGridLegacy: false,
            sharedMediaGridLegacy: false,
            storyLegacyVideoWriter: false,
            chatLegacyVideoWriter: false,
            chatSideListLegacy: false,
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
        coreListScrollTrace: Bool,
        chatMediaEditorLegacy: Bool,
        mediaGridLegacy: Bool,
        sharedMediaGridLegacy: Bool,
        storyLegacyVideoWriter: Bool,
        chatLegacyVideoWriter: Bool,
        chatSideListLegacy: Bool,
        respectSystemMicrophone: Bool,
        springSendAnimation: Bool,
        fakeWalletTransfers: Bool,
        useModernVideoMessagePipeline: Bool? = nil,
        videoMessageCameraMode: VideoMessageCameraMode = .hdBilinear,
        stickerRendererMode: StickerRendererMode = .gpuLarge,
        showCrashReportAlerts: Bool? = nil,
        videoMessageCloseFocus: Bool = true,
        videoMessageCameraMatrix: RoundVideoCameraMatrix = .bt709,
        tabletDisplayLinkFrameRateCap: Bool = false,
        displayLinkUpstreamRate: Bool = false,
        listAccessibilityImmediate: Bool = false,
        listScrollPacingLog: Bool = false,
        callsLivestreamHardwareDecoding: Bool = true,
        callsNativeCapturePath: Bool = true,
        callsSystemNoiseSuppression: Bool = true,
        callsAdvancedDucking: Bool = false,
        callsGroupNoiseMode: Int32 = 2,
        callsThermalVideoLadder: Bool = true,
        glassDebugDisabledGroups: Int32 = 0,
        emojiPanelDefersHeavyWork: Bool = false,
        chatOpenDeferSetup: Bool = false,
        chatScrollExperiments: Int32 = 0
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
        self.coreListScrollTrace = coreListScrollTrace
        self.chatMediaEditorLegacy = chatMediaEditorLegacy
        self.mediaGridLegacy = mediaGridLegacy
        self.sharedMediaGridLegacy = sharedMediaGridLegacy
        self.storyLegacyVideoWriter = storyLegacyVideoWriter
        self.chatLegacyVideoWriter = chatLegacyVideoWriter
        self.chatSideListLegacy = chatSideListLegacy
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
        self.displayLinkUpstreamRate = displayLinkUpstreamRate
        self.listAccessibilityImmediate = listAccessibilityImmediate
        self.listScrollPacingLog = listScrollPacingLog
        self.callsLivestreamHardwareDecoding = callsLivestreamHardwareDecoding
        self.callsNativeCapturePath = callsNativeCapturePath
        self.callsSystemNoiseSuppression = callsSystemNoiseSuppression
        self.callsAdvancedDucking = callsAdvancedDucking
        self.callsGroupNoiseMode = callsGroupNoiseMode
        self.callsThermalVideoLadder = callsThermalVideoLadder
        self.glassDebugDisabledGroups = glassDebugDisabledGroups
        self.emojiPanelDefersHeavyWork = emojiPanelDefersHeavyWork
        self.chatOpenDeferSetup = chatOpenDeferSetup
        self.chatScrollExperiments = chatScrollExperiments
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
        self.coreListScrollTrace = try container.decodeIfPresent(Bool.self, forKey: "coreListScrollTrace") ?? false
        self.chatMediaEditorLegacy = try container.decodeIfPresent(Bool.self, forKey: "chatMediaEditorLegacy") ?? false
        self.mediaGridLegacy = try container.decodeIfPresent(Bool.self, forKey: "mediaGridLegacy") ?? false
        self.sharedMediaGridLegacy = try container.decodeIfPresent(Bool.self, forKey: "sharedMediaGridLegacy") ?? false
        self.storyLegacyVideoWriter = try container.decodeIfPresent(Bool.self, forKey: "storyLegacyVideoWriter") ?? false
        self.chatLegacyVideoWriter = try container.decodeIfPresent(Bool.self, forKey: "chatLegacyVideoWriter") ?? false
        self.chatSideListLegacy = try container.decodeIfPresent(Bool.self, forKey: "chatSideListLegacy") ?? false
        self.respectSystemMicrophone = try container.decodeIfPresent(Bool.self, forKey: "respectSystemMicrophone") ?? false
        self.springSendAnimation = try container.decodeIfPresent(Bool.self, forKey: "springSendAnimation") ?? false
        self.fakeWalletTransfers = try container.decodeIfPresent(Bool.self, forKey: "fakeWalletTransfers") ?? false
        self.showCrashReportAlerts = try container.decodeIfPresent(Bool.self, forKey: "showCrashReportAlerts")
        self.useModernVideoMessagePipeline = try container.decodeIfPresent(Bool.self, forKey: "useModernVideoMessagePipeline")
        self.videoMessageCameraMode = (try container.decodeIfPresent(String.self, forKey: "videoMessageCameraMode")).flatMap(VideoMessageCameraMode.init(rawValue:)) ?? .hdBilinear
        self.stickerRendererMode = (try container.decodeIfPresent(String.self, forKey: "stickerRendererMode")).flatMap(StickerRendererMode.init(rawValue:)) ?? .gpuLarge
        // Stored under a new key since the default became on: every blob saved before that holds `false` under
        // the old "videoMessageCloseFocus" key whether or not the user touched the switch, so it is ignored.
        self.videoMessageCloseFocus = try container.decodeIfPresent(Bool.self, forKey: "videoMessageCloseFocusOn") ?? true
        // A new key: blobs saved before it existed (and unknown values) get the BT.709 default.
        self.videoMessageCameraMatrix = (try container.decodeIfPresent(String.self, forKey: "videoMessageCameraMatrix")).flatMap(RoundVideoCameraMatrix.init(rawValue:)) ?? .bt709
        self.tabletDisplayLinkFrameRateCap = try container.decodeIfPresent(Bool.self, forKey: "tabletDisplayLinkFrameRateCap") ?? false
        self.displayLinkUpstreamRate = try container.decodeIfPresent(Bool.self, forKey: "displayLinkUpstreamRate") ?? false
        self.listAccessibilityImmediate = try container.decodeIfPresent(Bool.self, forKey: "listAccessibilityImmediate") ?? false
        self.listScrollPacingLog = try container.decodeIfPresent(Bool.self, forKey: "listScrollPacingLog") ?? false
        // These four defaulted to off and became on (owner decision, 2026-11). The whole struct is saved on every change, so
        // an install that ever opened Debug Settings holds an explicit `false` under the old keys that the user never
        // chose. They are read from new keys (as with advanced ducking): only a choice made after the change counts.
        self.callsLivestreamHardwareDecoding = try container.decodeIfPresent(Bool.self, forKey: "callsLivestreamHardwareDecodingDefaultOn") ?? true
        self.callsNativeCapturePath = try container.decodeIfPresent(Bool.self, forKey: "callsNativeCapturePathDefaultOn") ?? true
        self.callsSystemNoiseSuppression = try container.decodeIfPresent(Bool.self, forKey: "callsSystemNoiseSuppressionDefaultOn") ?? true
        // A new key: it defaulted to on at first, so every blob saved under "callsAdvancedDucking" holds `true`
        // whether or not the user touched the switch. That value is ignored; the switch is off until A/B-tested.
        self.callsAdvancedDucking = try container.decodeIfPresent(Bool.self, forKey: "callsAdvancedDuckingOptIn") ?? false
        // The keys of the removed switches (low-latency encoder, narrowband processing, keep audio mode, background video drop)
        // are simply no longer read: those behaviours are always on.
        // Same for the group noise mode (it was 0, "both", unless chosen) and the thermal ladder.
        self.callsGroupNoiseMode = try container.decodeIfPresent(Int32.self, forKey: "callsGroupNoiseModeRNNoiseDefault") ?? 2
        self.callsThermalVideoLadder = try container.decodeIfPresent(Bool.self, forKey: "callsThermalVideoLadderDefaultOn") ?? true
        self.glassDebugDisabledGroups = try container.decodeIfPresent(Int32.self, forKey: "glassDebugDisabledGroups") ?? 0
        self.emojiPanelDefersHeavyWork = try container.decodeIfPresent(Bool.self, forKey: "emojiPanelDefersHeavyWork") ?? false
        self.chatOpenDeferSetup = try container.decodeIfPresent(Bool.self, forKey: "chatOpenDeferSetup") ?? false
        self.chatScrollExperiments = try container.decodeIfPresent(Int32.self, forKey: "chatScrollExperiments") ?? 0

        if savedDefaultsRevision < 1 {
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
        try container.encodeIfPresent(self.coreListScrollTrace, forKey: "coreListScrollTrace")
        try container.encodeIfPresent(self.chatMediaEditorLegacy, forKey: "chatMediaEditorLegacy")
        try container.encodeIfPresent(self.mediaGridLegacy, forKey: "mediaGridLegacy")
        try container.encodeIfPresent(self.sharedMediaGridLegacy, forKey: "sharedMediaGridLegacy")
        try container.encodeIfPresent(self.storyLegacyVideoWriter, forKey: "storyLegacyVideoWriter")
        try container.encodeIfPresent(self.chatLegacyVideoWriter, forKey: "chatLegacyVideoWriter")
        try container.encodeIfPresent(self.chatSideListLegacy, forKey: "chatSideListLegacy")
        try container.encodeIfPresent(self.respectSystemMicrophone, forKey: "respectSystemMicrophone")
        try container.encodeIfPresent(self.springSendAnimation, forKey: "springSendAnimation")
        try container.encodeIfPresent(self.fakeWalletTransfers, forKey: "fakeWalletTransfers")
        try container.encodeIfPresent(self.showCrashReportAlerts, forKey: "showCrashReportAlerts")
        try container.encodeIfPresent(self.useModernVideoMessagePipeline, forKey: "useModernVideoMessagePipeline")
        try container.encode(self.videoMessageCameraMode.rawValue, forKey: "videoMessageCameraMode")
        try container.encode(self.stickerRendererMode.rawValue, forKey: "stickerRendererMode")
        try container.encode(self.videoMessageCloseFocus, forKey: "videoMessageCloseFocusOn")
        try container.encode(self.videoMessageCameraMatrix.rawValue, forKey: "videoMessageCameraMatrix")
        try container.encode(self.tabletDisplayLinkFrameRateCap, forKey: "tabletDisplayLinkFrameRateCap")
        try container.encode(self.displayLinkUpstreamRate, forKey: "displayLinkUpstreamRate")
        try container.encode(self.listAccessibilityImmediate, forKey: "listAccessibilityImmediate")
        try container.encode(self.listScrollPacingLog, forKey: "listScrollPacingLog")
        try container.encode(self.callsLivestreamHardwareDecoding, forKey: "callsLivestreamHardwareDecodingDefaultOn")
        try container.encode(self.callsNativeCapturePath, forKey: "callsNativeCapturePathDefaultOn")
        try container.encode(self.callsSystemNoiseSuppression, forKey: "callsSystemNoiseSuppressionDefaultOn")
        try container.encode(self.callsAdvancedDucking, forKey: "callsAdvancedDuckingOptIn")
        try container.encode(self.callsGroupNoiseMode, forKey: "callsGroupNoiseModeRNNoiseDefault")
        try container.encode(self.callsThermalVideoLadder, forKey: "callsThermalVideoLadderDefaultOn")
        try container.encode(self.glassDebugDisabledGroups, forKey: "glassDebugDisabledGroups")
        try container.encode(self.emojiPanelDefersHeavyWork, forKey: "emojiPanelDefersHeavyWork")
        try container.encode(self.chatOpenDeferSetup, forKey: "chatOpenDeferSetup")
        try container.encode(self.chatScrollExperiments, forKey: "chatScrollExperiments")
        try container.encode(ExperimentalUISettings.nanogramDefaultsRevision, forKey: "nanogramDefaultsRevision")
    }
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
