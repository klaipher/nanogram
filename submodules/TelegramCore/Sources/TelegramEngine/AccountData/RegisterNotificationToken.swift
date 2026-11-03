import Foundation
import SwiftSignalKit
import Postbox
internal import TelegramApi


public enum NotificationTokenType {
    case aps(encrypt: Bool)
    case voip
}

func _internal_unregisterNotificationToken(account: Account, token: Data, type: NotificationTokenType, otherAccountUserIds: [PeerId.Id]) -> Signal<Never, NoError> {
    let mappedType: Int32
    switch type {
        case .aps:
            mappedType = 1
        case .voip:
            mappedType = 9
    }
    return account.network.request(Api.functions.account.unregisterDevice(tokenType: mappedType, token: hexString(token), otherUids: otherAccountUserIds.map({ $0._internalGetInt64Value() })))
    |> retryRequest
    |> ignoreValues
}

func _internal_registerNotificationToken(account: Account, token: Data, type: NotificationTokenType, sandbox: Bool, otherAccountUserIds: [PeerId.Id], excludeMutedChats: Bool) -> Signal<Bool, NoError> {
    return masterNotificationsKey(account: account, ignoreDisabled: false)
    |> mapToSignal { masterKey -> Signal<Bool, NoError> in
        let mappedType: Int32
        var keyData = Data()
        switch type {
            case let .aps(encrypt):
                mappedType = 1
                if encrypt {
                    keyData = masterKey.data
                }
            case .voip:
                mappedType = 9
                keyData = masterKey.data
        }
        var flags: Int32 = 0
        if excludeMutedChats {
            flags |= 1 << 0
        }
        return account.network.request(Api.functions.account.registerDevice(flags: flags, tokenType: mappedType, token: hexString(token), appSandbox: sandbox ? .boolTrue : .boolFalse, secret: Buffer(data: keyData), otherUids: otherAccountUserIds.map({ $0._internalGetInt64Value() })))
        |> map { _ -> Bool in
            return true
        }
        |> `catch` { error -> Signal<Bool, NoError> in
            let failure = notificationTokenRegistrationFailure(errorDescription: error.errorDescription, type: type, sandbox: sandbox)
            Logger.shared.log("RegisterNotificationToken", failure.logLine)
            return .single(failure.registered)
        }
    }
}

/// A failed `account.registerDevice`: only an invalidated token counts as not registered (the
/// caller drops it); any other error is treated as registered, as upstream does, so a token the
/// server keeps refusing is not retried forever. The log line names the error, never the token.
func notificationTokenRegistrationFailure(errorDescription: String, type: NotificationTokenType, sandbox: Bool) -> (registered: Bool, logLine: String) {
    let typeName: String
    switch type {
    case .aps:
        typeName = "aps"
    case .voip:
        typeName = "voip"
    }
    return (errorDescription != "TOKEN_WAS_INVALIDATED", "registerDevice failed: \(errorDescription) (type \(typeName), sandbox \(sandbox))")
}
