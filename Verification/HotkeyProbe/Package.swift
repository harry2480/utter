// swift-tools-version: 6.2
import PackageDescription

// Phase 0 検証 #51 用の使い捨てプロトタイプ。本番コードではなく、Packages/ からは参照しない。
let package = Package(
  name: "HotkeyProbe",
  platforms: [.macOS(.v26)],
  dependencies: [
    .package(path: "../../Packages/UtterCore")
  ],
  targets: [
    .executableTarget(
      name: "HotkeyProbe",
      dependencies: [.product(name: "UtterCore", package: "UtterCore")]
    )
  ],
  swiftLanguageModes: [.v6]
)
