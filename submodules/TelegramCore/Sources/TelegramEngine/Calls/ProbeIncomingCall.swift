import Foundation
import SwiftSignalKit
import MtProtoKit
internal import TelegramApi

/// What `phone.receivedCall` says about a call the notification service extension is ringing.
public enum IncomingCallProbeResult: Equatable, Sendable {
    /// The server took the acknowledgement: the call still rings.
    case ringing
    /// The call is over (declined, answered elsewhere, hung up, expired); the RPC error's name.
    case ended(String)
    /// No answer worth acting on (timeout, offline, flood wait, a server error): the ring stays.
    case unknown
}

/// A 400 on a call id is the server saying the call is gone (`CALL_ALREADY_DECLINED`,
/// `CALL_PEER_INVALID`, ...), as `CallSessionManager` treats it. Any other failure says nothing
/// about the call, so a flaky network never takes a live ring down.
func incomingCallProbeResult(errorCode: Int32, errorDescription: String?) -> IncomingCallProbeResult {
    guard errorCode == 400 else {
        return .unknown
    }
    return .ended(CallDiagnostics.rpcErrorName(code: errorCode, description: errorDescription ?? ""))
}

/// Asks the server whether the incoming call `id` still rings, with the same request as the
/// acknowledgement. A timeout gives `.unknown`.
public func _internal_probeIncomingCall(network: Network, id: Int64, accessHash: Int64, timeout: Double, queue: Queue) -> Signal<IncomingCallProbeResult, NoError> {
    let request: Signal<IncomingCallProbeResult, NoError> = network.request(_internal_incomingCallAcknowledgementRequest(id: id, accessHash: accessHash))
    |> map { result -> IncomingCallProbeResult in
        if case .boolTrue = result {
            return .ringing
        }
        return .unknown
    }
    |> `catch` { error -> Signal<IncomingCallProbeResult, NoError> in
        return .single(incomingCallProbeResult(errorCode: error.errorCode, errorDescription: error.errorDescription))
    }
    return request
    |> timeout(timeout, queue: queue, alternate: .single(.unknown))
    |> take(1)
}
