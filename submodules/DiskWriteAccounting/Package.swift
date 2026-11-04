// swift-tools-version:5.5

import PackageDescription

let package = Package(
    name: "DiskWriteAccounting",
    platforms: [.macOS(.v10_13)],
    products: [
        .library(
            name: "DiskWriteAccounting",
            targets: ["DiskWriteAccounting"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "DiskWriteAccounting",
            dependencies: [],
            path: "Sources"),
        .testTarget(
            name: "DiskWriteAccountingTests",
            dependencies: [.target(name: "DiskWriteAccounting")],
            path: "Tests"),
    ]
)
