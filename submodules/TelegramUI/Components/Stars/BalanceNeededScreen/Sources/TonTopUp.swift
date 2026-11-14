import Foundation
import AccountContext
import TelegramPresentationData
import PresentationDataUtils
import InAppPurchaseManager
import Display

public func tonTopUpUrl(appConfiguration: AppConfiguration) -> String {
    if let data = appConfiguration.data, let value = data["ton_topup_url"] as? String {
        return value
    }
    return "https://fragment.com/ads/topup"
}

// Store builds must not steer to an outside payment for digital goods, so every TON top-up opener ends here.
public func openTonTopUp(context: AccountContext) {
    if !StorePurchasePolicy.current.allows(.tonTopUp) {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let alertController = textAlertController(context: context, title: nil, text: "TON can't be bought in this app. You can still spend the TON you already have.", actions: [TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})])
        context.sharedContext.presentGlobalController(alertController, nil)
        return
    }
    let url = tonTopUpUrl(appConfiguration: context.currentAppConfiguration.with { $0 })
    context.sharedContext.applicationBindings.openUrl(url)
}
