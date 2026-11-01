// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TDShim",
    platforms: [
        .iOS(.v17),
        .macOS(.v12),
        .watchOS(.v9),
    ],
    products: [
        .library(name: "TDShim", targets: ["TDShim"]),
    ],
    dependencies: [
        // Newest build of the TDLib schema that Sources/TDShim/Generated was generated from
        // (td_api.tl at 1.8.64-e0943d06 is identical to 49b3bcbb). 1.8.65+ changes types the
        // models decode (message, messageLocation, draftMessage, inputMessage*), so bumping
        // further needs the models regenerated first.
        .package(url: "https://github.com/Swiftgram/TDLibFramework", .exact("1.8.64-e0943d06")),
    ],
    targets: [
        .target(
            name: "TDShim",
            dependencies: [
                .product(name: "TDLibFramework", package: "TDLibFramework"),
            ],
            exclude: ["Generated/README.md"]
        ),
        .testTarget(
            name: "TDShimTests",
            dependencies: ["TDShim"]
        ),
    ]
)
