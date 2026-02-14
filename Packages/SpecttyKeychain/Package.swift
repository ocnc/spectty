// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SpecttyKeychain",
    platforms: [.iOS(.v18)],
    products: [
        .library(name: "SpecttyKeychain", targets: ["SpecttyKeychain"]),
    ],
    targets: [
        .target(name: "SpecttyKeychain"),
    ]
)
