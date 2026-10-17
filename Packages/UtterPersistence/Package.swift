// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "UtterPersistence",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "UtterPersistence", targets: ["UtterPersistence"])
  ],
  dependencies: [
    .package(path: "../UtterCore"),
    .package(url: "https://github.com/groue/GRDB.swift", exact: "7.11.1"),
  ],
  targets: [
    .target(
      name: "UtterPersistence",
      dependencies: ["UtterCore", .product(name: "GRDB", package: "GRDB.swift")]),
    .testTarget(name: "UtterPersistenceTests", dependencies: ["UtterPersistence"]),
  ],
  swiftLanguageModes: [.v6]
)
