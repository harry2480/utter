// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "UtterPersistence",
  // iOS の最低バージョンは Phase i0（#54）で確定するまでの仮の値。確定したら全 Package と Apps/iOS/project.yml をそろえて直す（scripts/verify.sh が一致を確かめる）
  platforms: [.macOS(.v26), .iOS(.v26)],
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
