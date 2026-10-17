// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "UtterPersistence",
  // iOS の最低バージョンは Phase i0（#54）で確定するまでの仮の値。確定したら全 Package をそろえて直す
  platforms: [.macOS(.v26), .iOS(.v26)],
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
