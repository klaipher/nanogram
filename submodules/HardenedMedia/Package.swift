// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HardenedMedia",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HardenedMedia", targets: ["HardenedMedia"]),
    ],
    targets: [
        .target(name: "HardenedMedia", path: "Sources"),
        .testTarget(name: "HardenedMediaTests", dependencies: ["HardenedMedia"], path: "Tests"),
    ]
)
