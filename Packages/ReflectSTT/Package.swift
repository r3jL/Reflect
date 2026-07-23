// swift-tools-version: 5.10
// ReflectSTT — on-device speech-to-text (§3.4): whisper.cpp v1.9.1 built
// as a static Metal-enabled xcframework (see docs/PHASE0_PLAN.md M8 for
// the rebuild recipe). Audio never leaves the device.
import PackageDescription

let package = Package(
    name: "ReflectSTT",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ReflectSTT", targets: ["ReflectSTT"])
    ],
    targets: [
        .binaryTarget(
            name: "CWhisper",
            path: "Vendor/whisper.xcframework"
        ),
        .target(
            name: "ReflectSTT",
            dependencies: ["CWhisper"],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("Accelerate"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("Foundation"),
            ]
        ),
        .testTarget(name: "ReflectSTTTests", dependencies: ["ReflectSTT"]),
    ]
)
