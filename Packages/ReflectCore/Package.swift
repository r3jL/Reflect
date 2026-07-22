// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ReflectCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ReflectCore", targets: ["ReflectCore"])
    ],
    targets: [
        .target(name: "ReflectCore"),
        .testTarget(name: "ReflectCoreTests", dependencies: ["ReflectCore"]),
    ]
)
