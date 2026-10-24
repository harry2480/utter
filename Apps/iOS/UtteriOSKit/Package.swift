// swift-tools-version: 6.2
import PackageDescription

// iOS 本体アプリのうち、OS の API を使わずにテストできる部分（録音セッションの進行・割り込みの変換・結果の保存先の選択・
// 同意・API キー・予算によるクラウド整形とローカル整形の振り分け）。
// アプリ（Apps/iOS/Sources）は AVAudioSession / AVAudioEngine / UIKit のアダプターと画面だけを持ち、これをリンクする。
// macOS でも `swift test` で検査できるよう macOS も宣言する（アプリとしては iOS 専用）。
let package = Package(
  name: "UtteriOSKit",
  // iOS の最低バージョンは Phase i0（#54）で確定するまでの仮の値。確定したら全 Package と Apps/iOS/project.yml をそろえて直す（scripts/verify.sh が一致を確かめる）
  platforms: [.macOS(.v26), .iOS(.v26)],
  products: [
    .library(name: "UtteriOSKit", targets: ["UtteriOSKit"])
  ],
  dependencies: [
    .package(path: "../../../Packages/UtterCore"),
    .package(path: "../../../Packages/UtterSpeech"),
    .package(path: "../../../Packages/UtterAI"),
    .package(path: "../../../Packages/UtterPersistence"),
  ],
  targets: [
    .target(
      name: "UtteriOSKit",
      dependencies: [
        .product(name: "UtterCore", package: "UtterCore"),
        .product(name: "UtterSpeech", package: "UtterSpeech"),
        .product(name: "UtterAI", package: "UtterAI"),
        .product(name: "UtterPersistence", package: "UtterPersistence"),
      ]),
    .testTarget(name: "UtteriOSKitTests", dependencies: ["UtteriOSKit"]),
  ],
  swiftLanguageModes: [.v6]
)
