import AppKit
import SwiftUI
import UtterCore

/// macOS アプリの起動部（Composition Root）。
///
/// メニューバーに常駐し、Dock には出さない（Info.plist の `LSUIElement`）。
/// 録音・挿入は Phase 0 の判定後に、`AppComposition` で本番実装と Stub を組み立てて結線する。
@main
struct UtterApp: App {
  @State private var composition = AppComposition()
  @State private var shortcuts = ShortcutCoordinator()

  var body: some Scene {
    MenuBarExtra("utter", systemImage: "mic") {
      Text(shortcuts.statusText)
      if let command = shortcuts.lastCommand {
        Text("最後の操作: \(Self.commandName(command))")
      }
      Divider()
      #if DEBUG
        Button("HUD のデモ（上限到達）") {
          composition.hudDemo.runLimitReached()
        }
        Button("HUD のデモ（失敗）") {
          composition.hudDemo.runFailure()
        }
        Divider()
      #endif
      Button("utter を終了") {
        NSApplication.shared.terminate(nil)
      }
      .keyboardShortcut("q")
    }
  }

  private static func commandName(_ command: ShortcutCommand) -> String {
    switch command {
    case .startRecording: "録音開始"
    case .stopRecording: "録音停止"
    case .cancelSession: "キャンセル"
    }
  }
}
