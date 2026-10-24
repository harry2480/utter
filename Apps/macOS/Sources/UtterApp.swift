import AppKit
import SwiftUI
import UtterCore

/// macOS アプリの起動部（Composition Root）。
///
/// メニューバーに常駐し、Dock には出さない（Info.plist の `LSUIElement`）。
/// 録音・ホットキー・HUD・挿入は Phase 0 の判定後に、ここで本番実装と Stub を組み立てて結線する。
@main
struct UtterApp: App {
  #if DEBUG
    /// Realtime Direct（AC-15, 実験機能）の実機確認用。Debug ビルドにだけ含める
    @State private var realtimeDirectDebug = RealtimeDirectDebugRunner()
  #endif

  var body: some Scene {
    MenuBarExtra("utter", systemImage: "mic") {
      #if DEBUG
        RealtimeDirectDebugMenu(runner: realtimeDirectDebug)
        Divider()
      #endif
      Button("utter を終了") {
        NSApplication.shared.terminate(nil)
      }
      .keyboardShortcut("q")
    }
  }
}
