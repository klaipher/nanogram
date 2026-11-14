# The platform-neutral QR Studio logic (look settings, colours, motion, code paths, pill state, export
# layout and the CoreGraphics export renderer), written once for the iOS app and the Mac app.
# It is a source set, not a module: QrStudioScreen (iOS) lists it in `srcs`, and the Mac's QrStudioUI
# package compiles the same files through SwiftPM symlinks. UIKit/AppKit views, the look's platform
# colours (QrStudioLook.swift) and the sticker decoders stay per app. A change here is a change for both apps.
filegroup(
    name = "Sources",
    srcs = glob(["Sources/**/*.swift"]),
    visibility = ["//submodules/TelegramUI/Components/QrStudioScreen:__pkg__"],
)
