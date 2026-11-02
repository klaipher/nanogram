import SwiftUI
import UIKit

/// A circular chat avatar (default 36pt, customizable via `size`). Renders (priority):
/// crisp downloaded photo; blurred minithumbnail placeholder; initials on a
/// per-chat color. When embedded in a `ScrollView`, drives viewport-based download
/// of the small photo via `.onScrollVisibilityChange` (same as `PhotoBubbleView`) —
/// only while the photo exists and hasn't downloaded yet. Outside a scroll
/// container (e.g. as a `ToolbarItem`), the visibility callback fires once on
/// appear and once on disappear, so the download path is "request on chat open,
/// cancel on chat close."
struct AvatarView: View {
    let avatar: AvatarVisual
    var onRequestDownload: (Int) -> Void = { _ in }
    var onCancelDownload: (Int) -> Void = { _ in }

    var size: CGFloat = 36

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        content
            .frame(width: size, height: size)
            .clipShape(Circle())
            .onScrollVisibilityChange(threshold: 0.01) { visible in
                guard let fileId = avatar.photoFileId, avatar.photoLocalPath == nil else { return }
                if visible {
                    onRequestDownload(fileId)
                } else {
                    onCancelDownload(fileId)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch avatar.kind {
        case .savedMessages:
            ZStack {
                Circle().fill(Color.accentColor)
                Image(systemName: "bookmark.fill")
                    .font(.system(size: size * 0.42))
                    .foregroundStyle(.white)
            }
        case .normal:
            if let path = avatar.photoLocalPath, let img = AvatarImages.photo(path: path, pointSize: size, scale: displayScale) {
                Image(uiImage: img).resizable().scaledToFill()
            } else if let data = avatar.mini, let img = AvatarImages.minithumbnail(data, photoFileId: avatar.photoFileId) {
                Image(uiImage: img).resizable().scaledToFill().blur(radius: 1.5)
            } else {
                ZStack {
                    Circle().fill(avatarPalette[avatar.colorIndex])
                    Text(avatar.initials)
                        .font(.system(size: size * 0.4, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
    }
}

/// Avatar images through `MediaImageCache`: a chat-list change re-evaluates every visible row,
/// and each used to read and decode its avatar file again.
enum AvatarImages {
    /// The downloaded photo (TDLib's 160 px small size), decoded at the size it is drawn.
    static func photo(path: String, pointSize: CGFloat, scale: CGFloat) -> UIImage? {
        let pixels = Int((pointSize * max(scale, 1)).rounded(.up))
        return MediaImageCache.image(path: path, format: .native, maxPixelSize: pixels)
    }

    /// The minithumbnail placeholder. A photo's minithumbnail never changes, so its file id
    /// keys it; without one it is decoded uncached.
    static func minithumbnail(_ data: Data, photoFileId: Int?) -> UIImage? {
        guard let photoFileId else { return UIImage(data: data) }
        return MediaImageCache.image(key: "avatar-mini|\(photoFileId)") { UIImage(data: data) }
    }
}

#if DEBUG
#Preview("Avatar — initials") {
    AvatarView(avatar: AvatarVisual(kind: .normal, initials: "JS", colorIndex: 0, photoFileId: nil, photoLocalPath: nil, mini: nil))
        .padding()
}

#Preview("Avatar — single initial") {
    AvatarView(avatar: AvatarVisual(kind: .normal, initials: "T", colorIndex: 5, photoFileId: nil, photoLocalPath: nil, mini: nil))
        .padding()
}

#Preview("Avatar — saved messages") {
    AvatarView(avatar: AvatarVisual(kind: .savedMessages, initials: "", colorIndex: 0, photoFileId: nil, photoLocalPath: nil, mini: nil))
        .padding()
}

#Preview("Avatar — empty title") {
    AvatarView(avatar: AvatarVisual(kind: .normal, initials: "", colorIndex: 3, photoFileId: nil, photoLocalPath: nil, mini: nil))
        .padding()
}
#endif
