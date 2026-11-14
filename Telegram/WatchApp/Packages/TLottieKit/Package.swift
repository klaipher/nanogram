// swift-tools-version:5.9
import PackageDescription

// tlottie is the Lottie renderer the phone and the Mac use too (submodules/tlottie/tlottie, a Rust crate).
// TLottieCore.xcframework is built from that source by Telegram/WatchApp/tools/build-tlottie-xcframework.sh
// (no_std static library, pinned nightly, -Zbuild-std; watchOS targets are Rust tier 3) and is not committed:
// Frameworks/ is generated. Run the script before opening, resolving or building the watch project.
let package = Package(
    name: "TLottieKit",
    platforms: [
        .watchOS(.v10),
        // The macOS slice exists only when the script ran with --macos (package tests on the Mac).
        .macOS(.v14)
    ],
    products: [
        .library(name: "TLottieKit", targets: ["TLottieKit"]),
    ],
    targets: [
        .binaryTarget(
            name: "TLottieCore",
            path: "Frameworks/TLottieCore.xcframework"
        ),
        .target(
            name: "TLottieKit",
            dependencies: ["TLottieCore"],
            path: "Sources/TLottieKit",
            linkerSettings: [
                .linkedLibrary("z"),
            ]
        ),
        .testTarget(
            name: "TLottieKitTests",
            dependencies: ["TLottieKit"],
            path: "Tests/TLottieKitTests",
            resources: [
                .copy("Resources/tiny.tgs"),
                .copy("Resources/tiny.json"),
                .copy("Resources/sticker_lottie.tgs"),
                .copy("Resources/dotlottie.tgs"),
            ]
        ),
    ]
)
