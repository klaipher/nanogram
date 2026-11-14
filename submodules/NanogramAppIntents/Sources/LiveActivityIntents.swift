import AppIntents
import Foundation
import NanogramGlance

/// Buttons on the Live Activity. A LiveActivityIntent runs in the app's process.
@available(iOS 17.0, *)
public struct StopLiveLocationIntent: LiveActivityIntent {
    public static let title: LocalizedStringResource = "Stop Sharing Location"

    @Parameter(title: "Account")
    public var accountId: Int

    @Parameter(title: "Chat")
    public var peerId: Int

    public init() {
    }

    public init(accountId: Int64, peerId: Int64) {
        self.accountId = Int(truncatingIfNeeded: accountId)
        self.peerId = Int(truncatingIfNeeded: peerId)
    }

    public func perform() async throws -> some IntentResult {
        guard let handler = await GlanceIntentBridge.shared.current() else {
            throw NanogramIntentError.notReady
        }
        await handler.stopLiveLocation(Int64(self.accountId), Int64(self.peerId))
        return .result()
    }
}

@available(iOS 17.0, *)
public struct EndCallIntent: LiveActivityIntent {
    public static let title: LocalizedStringResource = "End Call"

    public init() {
    }

    public func perform() async throws -> some IntentResult {
        guard let handler = await GlanceIntentBridge.shared.current() else {
            throw NanogramIntentError.notReady
        }
        await handler.endCall()
        return .result()
    }
}
