// swift-tools-version: 5.10
// ReflectCore — UI-independent domain core (spec §8): database, models,
// repositories, and (from Phase 1) the durable job queue.
import PackageDescription

let package = Package(
    name: "ReflectCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ReflectCore", targets: ["ReflectCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0")
    ],
    targets: [
        .target(
            name: "CSQLiteVec",
            cSettings: [
                // Statically linked into the app: resolve sqlite3_* against
                // the linked SQLite, not the extension API shim (see M0 spike).
                .define("SQLITE_CORE"),
                .define("SQLITE_VEC_STATIC"),
            ]
        ),
        .target(
            name: "ReflectCore",
            dependencies: [
                "CSQLiteVec",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(name: "ReflectCoreTests", dependencies: ["ReflectCore"]),
    ]
)
