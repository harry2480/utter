// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "UtterPersistence",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "UtterPersistence", targets: ["UtterPersistence"])
  ],
  dependencies: [
    .package(path: "../UtterCore")
  ],
  targets: [
    .target(name: "UtterPersistence", dependencies: ["UtterCore"]),
    .testTarget(name: "UtterPersistenceTests", dependencies: ["UtterPersistence"]),
  ],
  swiftLanguageModes: [.v6]
)
