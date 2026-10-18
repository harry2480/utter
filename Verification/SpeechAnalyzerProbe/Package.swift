// swift-tools-version: 6.2
import Foundation
import PackageDescription

// Phase 0 検証（#48）用の使い捨てプロトタイプ。Packages/ からは参照しない。
// 評価結果の JSON を UtterEvaluation（utter-eval）と同じ型で書くため、UtterEvaluation にだけ依存する。

// マイク・音声認識の権限ダイアログに用途を表示するため、Info.plist を実行ファイルに埋め込む。
let infoPlist = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()
  .appendingPathComponent("Support/Info.plist")
  .path

let package = Package(
  name: "SpeechAnalyzerProbe",
  platforms: [.macOS(.v26)],
  dependencies: [
    .package(path: "../../Packages/UtterEvaluation")
  ],
  targets: [
    .executableTarget(
      name: "SpeechAnalyzerProbe",
      dependencies: [.product(name: "UtterEvaluation", package: "UtterEvaluation")],
      linkerSettings: [
        .unsafeFlags([
          "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker",
          infoPlist,
        ])
      ]
    )
  ],
  swiftLanguageModes: [.v6]
)
