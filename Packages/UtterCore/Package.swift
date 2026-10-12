// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "UtterCore",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "UtterCore", targets: ["UtterCore"])
  ],
  targets: [
    .target(name: "UtterCore"),
    .testTarget(name: "UtterCoreTests", dependencies: ["UtterCore"]),
  ],
  swiftLanguageModes: [.v6]
)
