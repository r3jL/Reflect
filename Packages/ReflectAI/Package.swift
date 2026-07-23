// swift-tools-version: 5.10
// ReflectAI — provider abstraction, OpenRouter adapter, and the pipeline
// orchestrator + stages (spec §8).
import PackageDescription

let package = Package(
    name: "ReflectAI",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ReflectAI", targets: ["ReflectAI"])
    ],
    dependencies: [
        .package(path: "../ReflectCore")
    ],
    targets: [
        .target(
            name: "ReflectAI",
            dependencies: ["ReflectCore"]
        ),
        .testTarget(name: "ReflectAITests", dependencies: ["ReflectAI"]),
    ]
)
