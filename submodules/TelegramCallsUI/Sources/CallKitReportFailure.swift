import Foundation
import CallKit

enum CallKitReportFailureAction: Equatable {
    /// CallKit shows or silences the call itself: do nothing.
    case keepRinging
    /// CallKit cannot take the call at all: the app rings it without CallKit.
    case fallBackToNotification
    /// The system filtered the caller out: end the call.
    case hangUp
}

/// What the app does when CallKit refuses an incoming call it reported. Only a failure that says nothing
/// about the caller (an unknown error, a missing entitlement) falls back to ringing without CallKit;
/// a caller the system filters (block list, restricted sharing, protected, sensitive participants) is
/// declined, and Do Not Disturb or a call CallKit already shows is CallKit's own answer.
func callKitReportFailureAction(domain: String, code: Int) -> CallKitReportFailureAction {
    guard domain == CXErrorDomainIncomingCall else {
        return .fallBackToNotification
    }
    switch code {
    case 3, -3, CXErrorCodeIncomingCallError.Code.callUUIDAlreadyExists.rawValue:
        return .keepRinging
    case CXErrorCodeIncomingCallError.Code.unknown.rawValue, CXErrorCodeIncomingCallError.Code.unentitled.rawValue:
        return .fallBackToNotification
    default:
        return .hangUp
    }
}
