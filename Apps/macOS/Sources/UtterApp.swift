import AppKit
import SwiftUI
import UtterAI
import UtterCore

/// macOS アプリの起動部（Composition Root）。
///
/// メニューバーに常駐し、Dock には出さない（Info.plist の `LSUIElement`）。
/// 録音・ホットキー・HUD・挿入は Phase 0 の判定後に、ここで本番実装と Stub を組み立てて結線する。
/// Claude 整形を結線するときは、同じ `claudeAPIKeyStore` を `ClaudeProvider(apiKeyStore:)` に渡す（AC-12）。
@main
struct UtterApp: App {
  private static let claudeAPIKeyStore = KeychainAPIKeyStore.claude()

  @State private var claudeAPIKeySettings = APIKeySettingsModel(store: Self.claudeAPIKeyStore)

  var body: some Scene {
    MenuBarExtra("utter", systemImage: "mic") {
      SettingsMenuButton()
      Divider()
      Button("utter を終了") {
        NSApplication.shared.terminate(nil)
      }
      .keyboardShortcut("q")
    }
    Settings {
      ClaudeAPIKeySettingsView(model: claudeAPIKeySettings)
    }
  }
}

/// 設定画面を開くメニュー項目。Dock に出ないアプリでは設定画面が前面に来ないため、先にアプリを前面にする
private struct SettingsMenuButton: View {
  @Environment(\.openSettings) private var openSettings

  var body: some View {
    Button("設定…") {
      NSApplication.shared.activate()
      openSettings()
    }
    .keyboardShortcut(",")
  }
}
