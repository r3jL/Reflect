// swift-tools-version: 5.10
// DB de-risk spike: GRDB + WAL + FTS5 + statically-linked sqlite-vec (vec0).
import PackageDescription

let package = Package(
    name: "DBSpike",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "CSQLiteVec",
            cSettings: [
                // Compile as part of the app: resolve sqlite3_* against the
                // linked SQLite rather than the extension API shim.
                .define("SQLITE_CORE"),
                .define("SQLITE_VEC_STATIC"),
            ]
        ),
        .executableTarget(
            name: "DBSpike",
            dependencies: [
                "CSQLiteVec",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
    ]
)
