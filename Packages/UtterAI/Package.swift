// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "UtterAI",
  // iOS の最低バージョンは Phase i0（#54）で確定するまでの仮の値。確定したら全 Package をそろえて直す
  platforms: [.macOS(.v26), .iOS(.v26)],
  products: [
    .library(name: "UtterAI", targets: ["UtterAI"])
  ],
  dependencies: [
    .package(path: "../UtterCore"),
    .package(path: "../UtterText"),
    .package(path: "../UtterSpeech"),
  ],
  targets: [
    .target(name: "UtterAI", dependencies: ["UtterCore", "UtterText", "UtterSpeech"]),
    .testTarget(name: "UtterAITests", dependencies: ["UtterAI", "UtterCore", "UtterSpeech"]),
  ],
  swiftLanguageModes: [.v6]
)
