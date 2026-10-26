// swift-tools-version: 6.2
import PackageDescription

// WhisperKit を使う STT アダプター（UtterSpeech の `SegmentTranscriber` の本番実装）。
// Phase 0 #49（モデル選定）と #47（ライセンス確定）の判定待ちの先行実装のため、UtterSpeech とは別の Package にし、
// これをリンクしたターゲットだけが WhisperKit を取り込む。UtterSpeech をビルド・リンクしても WhisperKit は取得されない。
// scripts/verify.sh と CI はほかの Package と同じくビルド・テストする（WhisperKit の取得には通信が要る。テストはモデルを使わない）。
// 不採用になったら、この Package と、UtterSpeech の WhisperKit 用の型（docs/アーキテクチャ.md「WhisperKit アダプター」の表）を消せば外れる。
let package = Package(
  name: "UtterSpeechWhisperKit",
  // iOS の最低バージョンは Phase i0（#54）で確定するまでの仮の値。確定したら全 Package をそろえて直す
  platforms: [.macOS(.v26), .iOS(.v26)],
  products: [
    .library(name: "UtterSpeechWhisperKit", targets: ["UtterSpeechWhisperKit"])
  ],
  dependencies: [
    .package(path: "../UtterCore"),
    .package(path: "../UtterSpeech"),
    // バージョンを固定する（Package.resolved もコミットする）。版を上げたら docs/ライセンス・依存関係.md 2.1 を見直す。
    // リポジトリは argmaxinc/WhisperKit から改名された（同 2.1）
    .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.1"),
  ],
  targets: [
    .target(
      name: "UtterSpeechWhisperKit",
      dependencies: [
        "UtterCore",
        "UtterSpeech",
        .product(name: "WhisperKit", package: "argmax-oss-swift"),
      ]),
    .testTarget(name: "UtterSpeechWhisperKitTests", dependencies: ["UtterSpeechWhisperKit"]),
  ],
  swiftLanguageModes: [.v6]
)
