// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SpecttyTerminal",
    platforms: [.iOS(.v18), .macOS(.v13)],
    products: [
        .library(name: "SpecttyTerminal", targets: ["SpecttyTerminal"]),
    ],
    targets: [
        .binaryTarget(
            name: "GhosttyVt",
            url: "https://release.files.ghostty.org/libghostty-vt/1.0.1/ghostty-vt-1.0.1.xcframework.zip",
            checksum: "c0f9631277f726154c8f521954d17cdc41aac4626fc0df8cf925a19ee58e829b"
        ),
        .target(
            name: "SpecttyTerminal",
            dependencies: ["GhosttyVt"]
        ),
        .testTarget(name: "SpecttyTerminalTests", dependencies: ["SpecttyTerminal", "GhosttyVt"]),
    ]
)
