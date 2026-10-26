import AppKit
import SwiftUI
import UtterCore
import UtterPersistence

/// macOS アプリの起動部（Composition Root）。
///
/// メニューバーに常駐し、Dock には出さない（Info.plist の `LSUIElement`）。
/// 録音・ホットキー・挿入は Phase 0 の判定後に、`AppComposition` で本番実装と Stub を組み立てて結線する。
@main
struct UtterApp: App {
  @State private var composition = AppComposition()
  @State private var consentSettings = ConsentSettingsModel(
    controller: ConsentSettingsController(store: AppSettingsStore(defaults: .standard)))

  var body: some Scene {
    MenuBarExtra("utter", systemImage: "mic") {
      MenuContent(composition: composition)
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
  let composition: AppComposition
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    #if DEBUG
      Button("HUD のデモ（上限到達）") {
        composition.hudDemo.runLimitReached()
      }
      Button("HUD のデモ（失敗）") {
        composition.hudDemo.runFailure()
      }
      Divider()
    #endif
    Button("クラウド送信の同意…") {
      openWindow(id: WindowID.consentSettings)
      // Dock に出ないアプリのため、開いた画面を前面に出す
      NSApplication.shared.activate()
    }
    Divider()
    Button("utter を終了") {
      NSApplication.shared.terminate(nil)
    }
    .keyboardShortcut("q")
  }
}
