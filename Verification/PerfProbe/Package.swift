// swift-tools-version: 6.2
import PackageDescription

// Phase 0 検証（#52）用の使い捨てパッケージ。Packages/ からは参照しない。
let package = Package(
  name: "PerfProbe",
  platforms: [.macOS(.v26), .iOS(.v26)],
  products: [
    .library(name: "PerfProbe", targets: ["PerfProbe"]),
    .executable(name: "perf-probe-demo", targets: ["perf-probe-demo"]),
    .executable(name: "perf-probe-summarize", targets: ["perf-probe-summarize"]),
  ],
  targets: [
    // 区間名の定義と Signpost の発行。将来アプリ本体が同じ区間名を使えるよう、外部依存を持たない
    .target(name: "PerfProbe"),
    // xctrace の書き出し（XML）の読み取りと p50/p95 の集計
    .target(name: "PerfProbeAnalysis", dependencies: ["PerfProbe"]),
    .executableTarget(name: "perf-probe-demo", dependencies: ["PerfProbe"]),
    .executableTarget(name: "perf-probe-summarize", dependencies: ["PerfProbeAnalysis"]),
    .testTarget(name: "PerfProbeAnalysisTests", dependencies: ["PerfProbe", "PerfProbeAnalysis"]),
  ],
  swiftLanguageModes: [.v6]
)
