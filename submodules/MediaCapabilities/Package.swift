// swift-tools-version:5.5

import PackageDescription

let package = Package(
    name: "MediaCapabilities",
    platforms: [.macOS(.v10_13)],
    products: [
        .library(name: "MediaCapabilities", targets: ["MediaCapabilities"]),
    ],
    targets: [
        .target(
            name: "MediaCapabilities",
            path: "Sources",
            linkerSettings: [
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
            ]),
        .testTarget(
            name: "MediaCapabilitiesTests",
            dependencies: ["MediaCapabilities"],
            path: "Tests"),
    ]
)
