import AppKit
import SwiftUI
import UtterCore
import UtterPersistence

/// macOS アプリの起動部（Composition Root）。
///
/// メニューバーに常駐し、Dock には出さない（Info.plist の `LSUIElement`）。
/// 録音・ホットキー・HUD・挿入は Phase 0 の判定後に、ここで本番実装と Stub を組み立てて結線する。
@main
struct UtterApp: App {
  @State private var dictionaryEditor = DictionaryEditorModel {
    DictionaryStore(database: try UtterDatabase.open(at: AppDatabaseLocation.url()))
  }
  @State private var consentSettings = ConsentSettingsModel(
    controller: ConsentSettingsController(store: AppSettingsStore(defaults: .standard)))

  var body: some Scene {
    MenuBarExtra("utter", systemImage: "mic") {
      MenuContent()
    }
    Window("辞書", id: WindowID.dictionary) {
      DictionaryEditorView(model: dictionaryEditor)
    }
    Window("クラウド送信の同意", id: WindowID.consentSettings) {
      ConsentSettingsView(model: consentSettings)
    }
    .windowResizability(.contentMinSize)
  }
}

enum WindowID {
  static let dictionary = "dictionary"
  static let consentSettings = "consentSettings"
}

/// メニューバーのメニュー
private struct MenuContent: View {
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Button("辞書を編集…") {
      open(WindowID.dictionary)
    }
    Button("クラウド送信の同意…") {
      open(WindowID.consentSettings)
    }
    Divider()
    Button("utter を終了") {
      NSApplication.shared.terminate(nil)
    }
    .keyboardShortcut("q")
  }

  private func open(_ id: String) {
    openWindow(id: id)
    // Dock に出ないアプリのため、前面に出さないとウインドウがほかのアプリの後ろに開く
    NSApplication.shared.activate()
  }
}
