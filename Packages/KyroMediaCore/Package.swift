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
    .library(name: "KyroCapabilities", targets: ["KyroCapabilities"]),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-crypto", exact: "3.15.1")
  ],
  targets: [
    .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3", providers: [.apt(["libsqlite3-dev"])]),
    .target(
      name: "CArgon2", exclude: ["LICENSE", "PROVENANCE.md"],
      cSettings: [.headerSearchPath("src"), .define("ARGON2_NO_THREADS")]),
    .target(name: "KyroFoundation", dependencies: ["CSQLite"]),
    .target(
      name: "KyroCredentials",
      dependencies: ["CArgon2", .product(name: "Crypto", package: "swift-crypto")]),
    .target(name: "KyroIdentity", dependencies: ["KyroFoundation", "KyroCredentials"]),
    .target(name: "KyroLedger", dependencies: ["KyroFoundation"]),
    .target(name: "KyroCatalog", dependencies: ["KyroFoundation"]),
    .target(name: "KyroMatching", dependencies: ["KyroCatalog"]),
    .target(name: "KyroSources", dependencies: ["KyroFoundation", "KyroCatalog"]),
    .target(
      name: "KyroSourceJellyfin", dependencies: ["KyroFoundation", "KyroCatalog", "KyroSources"]),
    .target(
      name: "KyroSourceXtream", dependencies: ["KyroFoundation", "KyroCatalog", "KyroSources"]),
    .target(name: "KyroPlayback", dependencies: ["KyroFoundation"]),
    .target(name: "KyroCapabilities", dependencies: ["KyroFoundation"]),
    .testTarget(
      name: "KyroMediaCoreTests",
      dependencies: [
        "CArgon2", "KyroCredentials", "KyroFoundation", "KyroIdentity", "KyroLedger", "KyroCatalog",
        "KyroMatching", "KyroSources", "KyroSourceJellyfin", "KyroSourceXtream", "KyroPlayback",
        "KyroCapabilities",
      ]),
  ]
    + [
      "KyroFoundation", "KyroCredentials", "KyroIdentity", "KyroLedger", "KyroCatalog",
      "KyroMatching", "KyroSources", "KyroSourceJellyfin", "KyroSourceXtream", "KyroPlayback",
      "KyroCapabilities",
    ].map { module in
      var dependencies: [Target.Dependency] = [.target(name: module)]
      if module != "KyroFoundation" { dependencies.append("KyroFoundation") }
      if module == "KyroMatching" { dependencies.append("KyroCatalog") }
      if module == "KyroCredentials" {
        dependencies.append(.product(name: "Crypto", package: "swift-crypto"))
      }
      return .testTarget(name: module + "Tests", dependencies: dependencies)
    },
  swiftLanguageModes: [.v6]
)
