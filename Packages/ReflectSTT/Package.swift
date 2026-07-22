// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ReflectSTT",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ReflectSTT", targets: ["ReflectSTT"])
    ],
    targets: [
        .target(name: "ReflectSTT"),
        .testTarget(name: "ReflectSTTTests", dependencies: ["ReflectSTT"]),
    ]
)
