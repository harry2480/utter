// swift-tools-version: 6.2
import PackageDescription

// 精度評価（9章, AC-04）の計算と集計。アプリ・拡張・Worker からはリンクしない。
let package = Package(
  name: "UtterEvaluation",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "UtterEvaluation", targets: ["UtterEvaluation"]),
    .executable(name: "utter-eval", targets: ["utter-eval"]),
  ],
  targets: [
    .target(name: "UtterEvaluation"),
    .executableTarget(name: "utter-eval", dependencies: ["UtterEvaluation"]),
    .testTarget(name: "UtterEvaluationTests", dependencies: ["UtterEvaluation"]),
  ],
  swiftLanguageModes: [.v6]
)
