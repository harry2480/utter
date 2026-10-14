// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "UtterSpeech",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "UtterSpeech", targets: ["UtterSpeech"])
  ],
  dependencies: [
    .package(path: "../UtterCore")
  ],
  targets: [
    .target(name: "UtterSpeech", dependencies: ["UtterCore"]),
    .testTarget(name: "UtterSpeechTests", dependencies: ["UtterSpeech"]),
  ],
  swiftLanguageModes: [.v6]
)
