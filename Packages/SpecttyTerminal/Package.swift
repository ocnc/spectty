// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SpecttyTerminal",
    platforms: [.iOS(.v18)],
    products: [
        .library(name: "SpecttyTerminal", targets: ["SpecttyTerminal"]),
    ],
    targets: [
        .target(
            name: "CGhosttyVT",
            path: "Sources/CGhosttyVT",
            publicHeadersPath: "include"
        ),
        .target(
            name: "SpecttyTerminal",
            dependencies: ["CGhosttyVT"]
        ),
    ]
)
