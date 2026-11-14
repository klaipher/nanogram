// swift-tools-version:5.5

import PackageDescription

let package = Package(
    name: "MTProtoRustEngine",
    platforms: [.macOS(.v10_13)],
    products: [
        .library(
            name: "MTProtoRustEngine",
            targets: ["MTProtoRustEngine", "MTProtoRustEngineMapping"]),
    ],
    dependencies: [
        .package(name: "TelegramCore", path: "../TelegramCore"),
        .package(name: "MtProtoKit", path: "../MtProtoKit"),
        .package(name: "SSignalKit", path: "../SSignalKit"),
        .package(name: "EncryptionProvider", path: "../EncryptionProvider"),
        .package(name: "WebProxyTransport", path: "../WebProxyTransport"),
        .package(name: "RustLibraries", path: "../../../../packages/RustLibraries"),
    ],
    targets: [
        .target(
            name: "MTProtoRustEngineMapping",
            dependencies: [],
            path: "Sources/MTProtoRustEngineMapping"),
        .target(
            name: "MTProtoRustEngine",
            dependencies: [
                .product(name: "NanogramRustFFI", package: "RustLibraries", condition: nil),
                "MTProtoRustEngineMapping",
                .product(name: "TelegramCore", package: "TelegramCore", condition: nil),
                .product(name: "MtProtoKit", package: "MtProtoKit", condition: nil),
                .product(name: "SwiftSignalKit", package: "SSignalKit", condition: nil),
                .product(name: "WebProxyTransport", package: "WebProxyTransport", condition: nil),
            ],
            path: "Sources/MTProtoRustEngine"),
        .testTarget(
            name: "MTProtoRustEngineMappingTests",
            dependencies: ["MTProtoRustEngineMapping"],
            path: "Tests/MTProtoRustEngineMappingTests"),
        .testTarget(
            name: "MTProtoRustEngineTests",
            dependencies: [
                "MTProtoRustEngine",
                .product(name: "NanogramRustFFI", package: "RustLibraries", condition: nil),
                "MTProtoRustEngineMapping",
                .product(name: "TelegramCore", package: "TelegramCore", condition: nil),
                .product(name: "MtProtoKit", package: "MtProtoKit", condition: nil),
                .product(name: "SwiftSignalKit", package: "SSignalKit", condition: nil),
                .product(name: "EncryptionProvider", package: "EncryptionProvider", condition: nil),
            ],
            path: "Tests/MTProtoRustEngineTests"),
    ]
)
