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

  var body: some Scene {
    MenuBarExtra("utter", systemImage: "mic") {
      MenuContent()
    }
    Window("辞書", id: WindowID.dictionary) {
      DictionaryEditorView(model: dictionaryEditor)
    }
  }
}

enum WindowID {
  static let dictionary = "dictionary"
}

private struct MenuContent: View {
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Button("辞書を編集…") {
      openWindow(id: WindowID.dictionary)
      // Dock に出ないアプリのため、前面に出さないとウインドウがほかのアプリの後ろに開く
      NSApplication.shared.activate()
    }
    Divider()
    Button("utter を終了") {
      NSApplication.shared.terminate(nil)
    }
    .keyboardShortcut("q")
  }
}
