// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "UtterAI",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "UtterAI", targets: ["UtterAI"])
  ],
  dependencies: [
    .package(path: "../UtterCore"),
    .package(path: "../UtterText"),
  ],
  targets: [
    .target(name: "UtterAI", dependencies: ["UtterCore", "UtterText"]),
    .testTarget(name: "UtterAITests", dependencies: ["UtterAI"]),
  ],
  swiftLanguageModes: [.v6]
)
