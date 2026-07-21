// swift-tools-version: 5.10
// Editor de-risk spike: SwiftUI-wrapped NSTextView with Living Memory styling,
// margin-fade-on-typing, and idle autosave. Run with `swift run`.
import PackageDescription

let package = Package(
    name: "EditorSpike",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "EditorSpike")
    ]
)
