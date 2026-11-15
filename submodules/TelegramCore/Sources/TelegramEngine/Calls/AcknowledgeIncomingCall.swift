import Foundation
import SwiftSignalKit
internal import TelegramApi

/// `phone.receivedCall` for a call the notification service extension rings from a push, the request
/// the app sends when it learns of a ringing call. It is what moves the caller from "Waiting" to
/// "Ringing".
func _internal_incomingCallAcknowledgementRequest(id: Int64, accessHash: Int64) -> (FunctionDescription, Buffer, DeserializeFunctionResponse<Api.Bool>) {
    return Api.functions.phone.receivedCall(peer: .inputPhoneCall(.init(id: id, accessHash: accessHash)))
}

/// `phone.discardCall` (hang up) for a ringing call the app learned of only from a notification:
/// ends it without the call ever becoming a session of the account.
func _internal_declineIncomingCallRequest(id: Int64, accessHash: Int64, isVideo: Bool) -> (FunctionDescription, Buffer, DeserializeFunctionResponse<Api.Updates>) {
    return Api.functions.phone.discardCall(flags: isVideo ? (1 << 0) : 0, peer: .inputPhoneCall(.init(id: id, accessHash: accessHash)), duration: 0, reason: .phoneCallDiscardReasonHangup, connectionId: 0)
}

/// Declines the incoming call `id` straight on the server, without creating a call session.
/// Emits `true` when the server took it and `false` on an error (an expired call).
public func _internal_declineIncomingCall(network: Network, id: Int64, accessHash: Int64, isVideo: Bool) -> Signal<Bool, NoError> {
    return network.request(_internal_declineIncomingCallRequest(id: id, accessHash: accessHash, isVideo: isVideo))
    |> map { _ -> Bool in
        return true
    }
    |> `catch` { _ -> Signal<Bool, NoError> in
        return .single(false)
    }
}
