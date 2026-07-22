// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ReflectAI",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ReflectAI", targets: ["ReflectAI"])
    ],
    targets: [
        .target(name: "ReflectAI"),
        .testTarget(name: "ReflectAITests", dependencies: ["ReflectAI"]),
    ]
)
