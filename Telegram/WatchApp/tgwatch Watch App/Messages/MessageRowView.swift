import SwiftUI

/// One history row. It compares equal on its data (`row` and the two edge flags), not on its
/// callbacks, and the list applies `.equatable()`: a closure is a new value on every list body
/// pass, so without this every row's body ran again for every new message. The callbacks read
/// the list's `@State` and store through references, so a row keeping an older closure behaves
/// the same.
struct MessageRowView: View, Equatable {
    let row: MessageRow
    let onPhotoTap: (PhotoVisual) -> Void
    let onVideoTap: (VideoVisual) -> Void
    let onVideoNoteTap: (VideoNoteVisual) -> Void
    let onPollTap: (Int64, PollVisual) -> Void
    /// Among the first three rows: becoming visible asks for older history.
    var isNearTop: Bool = false
    /// Among the last three rows: becoming visible asks for newer history.
    var isNearBottom: Bool = false
    var onEnterTopEdge: (() -> Void)? = nil
    var onEnterBottomEdge: (() -> Void)? = nil
    var onIncomingBubbleVisible: ((Int64) -> Void)? = nil

    var body: some View {
        rowBody
            .onScrollVisibilityChange(threshold: 0.01) { visible in
                guard visible else { return }
                if isNearTop { onEnterTopEdge?() }
                if isNearBottom { onEnterBottomEdge?() }
            }
    }

    struct Edges: Equatable {
        let nearTop: Bool
        let nearBottom: Bool
    }

    static func edges(index: Int, count: Int) -> Edges {
        Edges(nearTop: index <= 2, nearBottom: index >= count - 3)
    }

    nonisolated static func == (lhs: MessageRowView, rhs: MessageRowView) -> Bool {
        lhs.row == rhs.row && lhs.isNearTop == rhs.isNearTop && lhs.isNearBottom == rhs.isNearBottom
    }

    @ViewBuilder
    private var rowBody: some View {
        switch row {
        case .bubble(let b):
            MessageBubbleView(bubble: b, onPhotoTap: onPhotoTap, onVideoTap: onVideoTap, onVideoNoteTap: onVideoNoteTap, onPollTap: onPollTap)
                .onScrollVisibilityChange(threshold: 0.5) { visible in
                    guard visible, !b.isOutgoing else { return }
                    onIncomingBubbleVisible?(b.messageId)
                }
        case .service(let s):      ServiceMessageView(line: s)
        case .daySeparator(let d): DaySeparatorView(label: d)
        case .unreadDivider:       UnreadDividerView()
        }
    }
}
