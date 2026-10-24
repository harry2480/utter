import SwiftUI
import UtterCore

/// iOS 本体アプリの起動部（Composition Root）。
///
/// 現在は起動画面だけを表示する。録音・STT・整形・結果保存は Phase i0 の判定後に、
/// ここで本番実装と Stub を組み立てて結線する。
@main
struct UtterApp: App {
  var body: some Scene {
    WindowGroup {
      VStack(spacing: 12) {
        Image(systemName: "mic")
          .font(.largeTitle)
          .accessibilityHidden(true)
        Text("utter")
          .font(.title)
      }
    }
  }
}
