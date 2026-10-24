// swift-tools-version: 6.2
import PackageDescription

// Phase 0 検証（#41）用の使い捨てプロトタイプ。本番コードではない。Packages/ からは参照しない。
let package = Package(
  name: "AXInsertionProbe",
  platforms: [.macOS(.v26)],
  products: [
    .executable(name: "ax-insertion-probe", targets: ["AXInsertionProbe"])
  ],
  dependencies: [
    // 挿入結果の分類（INS-05）とクリップボード復元の判定（INS-04）を本番と同じ規則にそろえるため参照する
    .package(path: "../../Packages/UtterCore")
  ],
  targets: [
    .executableTarget(
      name: "AXInsertionProbe",
      dependencies: [.product(name: "UtterCore", package: "UtterCore")]
    )
  ],
  swiftLanguageModes: [.v6]
)
