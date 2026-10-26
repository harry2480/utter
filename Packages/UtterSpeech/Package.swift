// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "UtterSpeech",
  // iOS の最低バージョンは Phase i0（#54）で確定するまでの仮の値。確定したら全 Package と Apps/iOS/project.yml をそろえて直す（scripts/verify.sh が一致を確かめる）
  platforms: [.macOS(.v26), .iOS(.v26)],
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
