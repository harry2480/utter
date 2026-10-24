// swift-tools-version: 6.2
import PackageDescription

// Phase 0 検証（#49）用の使い捨てプロトタイプ。本番コードではなく、Packages/ からは参照しない。
// WhisperKit は重い依存のため scripts/verify.sh には組み込まない（README の手順で手動ビルドする）。
let package = Package(
  name: "WhisperKitProbe",
  platforms: [.macOS(.v26)],
  products: [
    .executable(name: "whisperkit-probe", targets: ["WhisperKitProbe"])
  ],
  dependencies: [
    // バージョンを固定する（Package.resolved もコミットする）
    .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.1.1"),
    .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.8.2"),
    // 評価結果の JSON を UtterEvaluation と同じ型で書き出すため
    .package(path: "../../Packages/UtterEvaluation"),
  ],
  targets: [
    .executableTarget(
      name: "WhisperKitProbe",
      dependencies: [
        .product(name: "WhisperKit", package: "WhisperKit"),
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        .product(name: "UtterEvaluation", package: "UtterEvaluation"),
      ]
    )
  ],
  swiftLanguageModes: [.v6]
)
