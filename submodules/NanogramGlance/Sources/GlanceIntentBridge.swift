public import Foundation

public enum GlanceSendResult: Sendable, Equatable {
    case queued
    case locked
    case unavailable
}

/// What the App Intents ask of the running app. The app registers it once its accounts are up; an intent that runs
/// before that waits briefly.
public struct GlanceIntentHandler: Sendable {
    public var openChat: @Sendable (_ accountId: Int64, _ peerId: Int64) async -> Bool
    public var sendToSavedMessages: @Sendable (_ accountId: Int64?, _ text: String) async -> GlanceSendResult
    public var stopLiveLocation: @Sendable (_ accountId: Int64, _ peerId: Int64) async -> Void
    public var endCall: @Sendable () async -> Void

    public init(
        openChat: @escaping @Sendable (Int64, Int64) async -> Bool,
        sendToSavedMessages: @escaping @Sendable (Int64?, String) async -> GlanceSendResult,
        stopLiveLocation: @escaping @Sendable (Int64, Int64) async -> Void,
        endCall: @escaping @Sendable () async -> Void
    ) {
        self.openChat = openChat
        self.sendToSavedMessages = sendToSavedMessages
        self.stopLiveLocation = stopLiveLocation
        self.endCall = endCall
    }
}

public actor GlanceIntentBridge {
    public static let shared = GlanceIntentBridge()

    private var handler: GlanceIntentHandler?

    public func register(_ handler: GlanceIntentHandler?) {
        self.handler = handler
    }

    public func current() -> GlanceIntentHandler? {
        return self.handler
    }

    /// The handler, waiting up to `timeout` seconds for the app to register it.
    public func waitForHandler(timeout: Double) async -> GlanceIntentHandler? {
        var waited = 0.0
        while self.handler == nil && waited < timeout {
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 0.1
        }
        return self.handler
    }
}
