// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ReflectMedia",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ReflectMedia", targets: ["ReflectMedia"])
    ],
    targets: [
        .target(name: "ReflectMedia"),
        .testTarget(name: "ReflectMediaTests", dependencies: ["ReflectMedia"]),
    ]
)
