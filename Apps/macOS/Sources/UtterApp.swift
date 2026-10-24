import AppKit
import SwiftUI
import UtterAI
import UtterCore
import UtterPersistence

/// macOS アプリの起動部（Composition Root）。
///
/// メニューバーに常駐し、Dock には出さない（Info.plist の `LSUIElement`）。
/// 録音・ホットキー・HUD・挿入は Phase 0 の判定後に、ここで本番実装と Stub を組み立てて結線する。
/// Claude 整形を結線するときは、同じ `claudeAPIKeyStore` を `ClaudeProvider(apiKeyStore:)` に渡す（AC-12）。
@main
struct UtterApp: App {
  private static let claudeAPIKeyStore = KeychainAPIKeyStore.claude()

  @State private var claudeAPIKeySettings = APIKeySettingsModel(store: Self.claudeAPIKeyStore)
  @State private var consentSettings = ConsentSettingsModel(
    controller: ConsentSettingsController(store: AppSettingsStore(defaults: .standard)))

  var body: some Scene {
    MenuBarExtra("utter", systemImage: "mic") {
      MenuContent()
    }
    Settings {
      ClaudeAPIKeySettingsView(model: claudeAPIKeySettings)
    }
    Window("クラウド送信の同意", id: WindowID.consentSettings) {
      ConsentSettingsView(model: consentSettings)
    }
    .windowResizability(.contentMinSize)
  }
}

enum WindowID {
  static let consentSettings = "consentSettings"
}

/// メニューバーのメニュー
private struct MenuContent: View {
  @Environment(\.openSettings) private var openSettings
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    // Dock に出ないアプリでは開いた画面が前面に来ないため、アプリを前面に出す
    Button("設定…") {
      NSApplication.shared.activate()
      openSettings()
    }
    .keyboardShortcut(",")
    Button("クラウド送信の同意…") {
      openWindow(id: WindowID.consentSettings)
      NSApplication.shared.activate()
    }
    Divider()
    Button("utter を終了") {
      NSApplication.shared.terminate(nil)
    }
    .keyboardShortcut("q")
  }
}
