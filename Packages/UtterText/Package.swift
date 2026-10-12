// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "UtterText",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "UtterText", targets: ["UtterText"])
  ],
  dependencies: [
    .package(path: "../UtterCore")
  ],
  targets: [
    .target(name: "UtterText", dependencies: ["UtterCore"]),
    .testTarget(name: "UtterTextTests", dependencies: ["UtterText"]),
  ],
  swiftLanguageModes: [.v6]
)
