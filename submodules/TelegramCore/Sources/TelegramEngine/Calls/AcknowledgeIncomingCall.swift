import Foundation
import SwiftSignalKit
internal import TelegramApi

/// `phone.receivedCall` for a call the notification service extension rings from a push, the request
/// the app sends when it learns of a ringing call. It is what moves the caller from "Waiting" to
/// "Ringing".
func _internal_incomingCallAcknowledgementRequest(id: Int64, accessHash: Int64) -> (FunctionDescription, Buffer, DeserializeFunctionResponse<Api.Bool>) {
    return Api.functions.phone.receivedCall(peer: .inputPhoneCall(.init(id: id, accessHash: accessHash)))
}

/// Tells the server this device received the incoming call `id`. Emits `true` when it accepted and
/// `false` on an error (an expired call, a revoked key): the ring is never held back by it.
public func _internal_acknowledgeIncomingCall(network: Network, id: Int64, accessHash: Int64) -> Signal<Bool, NoError> {
    return network.request(_internal_incomingCallAcknowledgementRequest(id: id, accessHash: accessHash))
    |> map { result -> Bool in
        if case .boolTrue = result {
            return true
        }
        return false
    }
    |> `catch` { _ -> Signal<Bool, NoError> in
        return .single(false)
    }
}
