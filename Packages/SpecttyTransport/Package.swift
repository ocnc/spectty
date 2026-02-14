// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SpecttyTransport",
    platforms: [.iOS(.v18)],
    products: [
        .library(name: "SpecttyTransport", targets: ["SpecttyTransport"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.9.0"),
        .package(path: "../SpecttyTerminal"),
    ],
    targets: [
        .target(
            name: "SpecttyTransport",
            dependencies: [
                "SpecttyTerminal",
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
            ]
        ),
    ]
)
