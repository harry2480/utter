import AppKit
import SwiftUI
import UtterCore

/// macOS アプリの起動部（Composition Root）。
///
/// メニューバーに常駐し、Dock には出さない（Info.plist の `LSUIElement`）。
/// 録音・ホットキー・HUD・挿入は Phase 0 の判定後に、ここで本番実装と Stub を組み立てて結線する。
@main
struct UtterApp: App {
  /// 自動更新。appcast URL と公開鍵がビルド設定で与えられていなければ Sparkle を起動しない（既定無効）。
  @State private var updater = SoftwareUpdater(infoDictionary: Bundle.main.infoDictionary ?? [:])

  var body: some Scene {
    MenuBarExtra("utter", systemImage: "mic") {
      if updater.isAvailable {
        Button("アップデートを確認…") {
          updater.checkForUpdates()
        }
        .disabled(!updater.canCheckForUpdates)
        Toggle(
          "アップデートを自動で確認",
          isOn: Binding(
            get: { updater.automaticallyChecksForUpdates },
            set: { updater.setAutomaticallyChecksForUpdates($0) }))
        Divider()
      }
      Button("utter を終了") {
        NSApplication.shared.terminate(nil)
      }
      .keyboardShortcut("q")
    }
  }
}
