// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "UtterCore",
  // iOS の最低バージョンは Phase i0（#54）で確定するまでの仮の値。確定したら全 Package をそろえて直す
  platforms: [.macOS(.v26), .iOS(.v26)],
  products: [
    .library(name: "UtterCore", targets: ["UtterCore"])
  ],
  targets: [
    .target(name: "UtterCore"),
    .testTarget(name: "UtterCoreTests", dependencies: ["UtterCore"]),
  ],
  swiftLanguageModes: [.v6]
)
