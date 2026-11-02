import Foundation
import SwiftSignalKit

/// How many of the forwarded messages the forward-options preview has selected: `initialCount`
/// until the preview chat reports a state, then its selection (1 without one), once per change.
///
/// The forward-options menu (`chatForwardOptions` in TelegramUI) rebuilds its items, and the context
/// controller relays itself out with a spring, on every value of this signal, while the preview chat
/// publishes its whole interface state on every update, most of which leave the selection alone.
public func chatForwardOptionsSelectedCount(initialCount: Int, previewInterfaceStates: Signal<ChatInterfaceState, NoError>) -> Signal<Int, NoError> {
    return .single(initialCount)
    |> then(
        previewInterfaceStates
        |> map { state -> Int in
            return state.selectionState?.selectedIds.count ?? 1
        }
    )
    |> distinctUntilChanged
}
