// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SpecttySpeech",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [.library(name: "SpecttySpeech", targets: ["SpecttySpeech"])],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git",
                 revision: "d653a34a620c013febd7530427b4963ae18064b2", traits: []),
    ],
    targets: [
        .target(name: "SpecttySpeech", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")], resources: [.process("Resources")]),
        .testTarget(name: "SpecttySpeechTests", dependencies: ["SpecttySpeech"]),
    ]
)
