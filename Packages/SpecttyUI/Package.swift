// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SpecttyUI",
    platforms: [.iOS(.v18)],
    products: [
        .library(name: "SpecttyUI", targets: ["SpecttyUI"]),
    ],
    dependencies: [
        .package(path: "../SpecttyTerminal"),
    ],
    targets: [
        .target(
            name: "SpecttyUI",
            dependencies: ["SpecttyTerminal"]
        ),
    ]
)
