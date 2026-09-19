// swift-tools-version: 6.0

import PackageDescription
import Foundation

let isMacAppStoreBuild = ProcessInfo.processInfo.environment["GALAXYBRIDGE_APP_STORE"] == "1"
var galaxyBridgeMacDependencies: [Target.Dependency] = [
    "GalaxyBridgeCore",
    "GalaxyBridgeProtocol",
    "GalaxyBridgeBuildPins",
    "CSQLite",
]
if !isMacAppStoreBuild {
    galaxyBridgeMacDependencies.append("GalaxyBridgeEnhancedCore")
    galaxyBridgeMacDependencies.append("GalaxyBridgeQuicBackend")
}
let quicBackendLibrary = ProcessInfo.processInfo.environment["GB_QUIC_BACKEND_LIBRARY"]
    ?? "\(URL(fileURLWithPath: #filePath).deletingLastPathComponent().path)/out/macos-arm64-release/artifacts/quic-backend/libgalaxybridge_quic_backend-macos-arm64.a"
let quicBackendLink: [LinkerSetting] = isMacAppStoreBuild ? [] : [
    .unsafeFlags([quicBackendLibrary]), .linkedLibrary("c++"), .linkedLibrary("iconv"),
    .linkedFramework("SystemConfiguration"),
]

let package = Package(
    name: "GalaxyBridge",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "CSQLite", targets: ["CSQLite"]),
        .library(name: "GalaxyBridgeCore", targets: ["GalaxyBridgeCore"]),
        .library(name: "GalaxyBridgeEnhancedCore", targets: ["GalaxyBridgeEnhancedCore"]),
        .library(name: "GalaxyBridgeProtocol", targets: ["GalaxyBridgeProtocol"]),
        .executable(name: "GalaxyBridgeMac", targets: ["GalaxyBridgeMac"]),
        .executable(name: "GalaxyBridgeCoreSpec", targets: ["GalaxyBridgeCoreSpec"]),
        .executable(name: "GalaxyBridgeLANIntegrationSpec", targets: ["GalaxyBridgeLANIntegrationSpec"]),
        .executable(name: "GalaxyBridgeProtocolSpec", targets: ["GalaxyBridgeProtocolSpec"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.38.1"),
    ],
    targets: [
        .target(name: "GalaxyBridgeBuildPins", path: ProcessInfo.processInfo.environment["GB_BUILD_PINS_DIRECTORY"] ?? "Sources/GalaxyBridgeBuildPins"),
        .systemLibrary(name: "GalaxyBridgeQuicBackend", path: "native/galaxybridge-quic-backend/include"),
        .systemLibrary(
            name: "CSQLite",
            path: "Sources/CSQLite"
        ),
        .target(name: "GalaxyBridgeCore"),
        .target(
            name: "GalaxyBridgeEnhancedCore",
            dependencies: ["GalaxyBridgeCore", "GalaxyBridgeBuildPins"]
        ),
        .target(
            name: "GalaxyBridgeProtocol",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            path: "protocol",
            exclude: ["fixtures"],
            plugins: [
                .plugin(name: "SwiftProtobufPlugin", package: "swift-protobuf"),
            ]
        ),
        .executableTarget(
            name: "GalaxyBridgeCoreSpec",
            dependencies: ["GalaxyBridgeCore", "GalaxyBridgeEnhancedCore"]
        ),
        .executableTarget(
            name: "GalaxyBridgeLANIntegrationSpec",
            dependencies: ["GalaxyBridgeCore", "GalaxyBridgeProtocol"]
        ),
        .executableTarget(
            name: "GalaxyBridgeProtocolSpec",
            dependencies: ["GalaxyBridgeProtocol"]
        ),
        .executableTarget(
            name: "GalaxyBridgeMac",
            dependencies: galaxyBridgeMacDependencies,
            path: "macos/GalaxyBridgeMac",
            exclude: ["Info.plist", "Assets.xcassets", "Resources"],
            swiftSettings: isMacAppStoreBuild ? [.define("GALAXYBRIDGE_APP_STORE")]
                : quicBackendLibrary.hasSuffix("-qa.a") ? [.define("GB_QUIC_BACKEND_QA")] : [],
            linkerSettings: quicBackendLink + [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreImage"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("GameController"),
                .linkedFramework("MetalKit"),
                .linkedFramework("Network"),
                .linkedFramework("Security"),
                .linkedFramework("SystemExtensions"),
                .linkedFramework("VideoToolbox"),
            ]
        ),
        .testTarget(
            name: "GalaxyBridgeMacKeyboardTests",
            dependencies: [
                "GalaxyBridgeCore",
                "GalaxyBridgeMac",
            ],
            path: "macos/GalaxyBridgeMacKeyboardTests",
            swiftSettings: (!isMacAppStoreBuild && quicBackendLibrary.hasSuffix("-qa.a")) ? [.define("GB_QUIC_BACKEND_QA")] : []
        ),
    ]
)
