import Foundation
import SwiftSignalKit

func chatFolderUpdatesCheckInterval(isDebug: Bool) -> Double {
    return isDebug ? 10.0 : 60.0
}

#if DEBUG
let chatFolderUpdatesCheckInterval: Double = chatFolderUpdatesCheckInterval(isDebug: true)
#else
let chatFolderUpdatesCheckInterval: Double = chatFolderUpdatesCheckInterval(isDebug: false)
#endif

func repeatedChatFolderUpdatesCheck(_ check: Signal<Never, NoError>, interval: Double) -> Signal<Never, NoError> {
    return (
        check
        |> then(
            Signal<Never, NoError>.complete()
            |> delay(interval, queue: .concurrentDefaultQueue())
        )
    )
    |> restart
}
