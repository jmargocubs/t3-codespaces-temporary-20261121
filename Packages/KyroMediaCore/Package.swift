// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KyroMediaCore",
    platforms: [.iOS(.v18), .tvOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "KyroFoundation", targets: ["KyroFoundation"]),
        .library(name: "KyroIdentity", targets: ["KyroIdentity"]),
        .library(name: "KyroCredentials", targets: ["KyroCredentials"]),
        .library(name: "KyroLedger", targets: ["KyroLedger"]),
        .library(name: "KyroCatalog", targets: ["KyroCatalog"]),
        .library(name: "KyroMatching", targets: ["KyroMatching"]),
        .library(name: "KyroSources", targets: ["KyroSources"]),
        .library(name: "KyroSourceJellyfin", targets: ["KyroSourceJellyfin"]),
        .library(name: "KyroSourceXtream", targets: ["KyroSourceXtream"]),
        .library(name: "KyroPlayback", targets: ["KyroPlayback"]),
        .library(name: "KyroCapabilities", targets: ["KyroCapabilities"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto", from: "3.12.0"),
        .package(url: "https://github.com/stephencelis/SQLite.swift", from: "0.15.3")
    ],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3", providers: [.apt(["libsqlite3-dev"])]),
        .target(name: "KyroFoundation", dependencies: ["CSQLite"]),
        .target(name: "KyroCredentials", dependencies: [.product(name: "Crypto", package: "swift-crypto")]),
        .target(name: "KyroIdentity", dependencies: ["KyroFoundation", "KyroCredentials"]),
        .target(name: "KyroLedger", dependencies: ["KyroFoundation"]),
        .target(name: "KyroCatalog", dependencies: ["KyroFoundation"]),
        .target(name: "KyroMatching", dependencies: ["KyroCatalog"]),
        .target(name: "KyroSources", dependencies: ["KyroCatalog"]),
        .target(name: "KyroSourceJellyfin", dependencies: ["KyroSources"]),
        .target(name: "KyroSourceXtream", dependencies: ["KyroSources"]),
        .target(name: "KyroPlayback", dependencies: ["KyroFoundation"]),
        .target(name: "KyroCapabilities", dependencies: ["KyroFoundation"]),
        .testTarget(name: "KyroMediaCoreTests", dependencies: ["KyroFoundation", "KyroIdentity", "KyroLedger", "KyroCatalog", "KyroMatching", "KyroSources", "KyroSourceJellyfin", "KyroSourceXtream", "KyroPlayback", "KyroCapabilities"])
    ],
    swiftLanguageModes: [.v6]
)
