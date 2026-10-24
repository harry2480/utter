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
  @State private var historyModels: InputHistoryModelProvider

  init() {
    let database = AppDatabaseProvider()
    // 設定の保存先。履歴への記録を結線するときも同じ保存先を読む（無効化は設定を先に書いてから削除するため）
    let settingsStore = AppSettingsStore(defaults: .standard)
    _historyModels = State(
      initialValue: InputHistoryModelProvider(database: database, settingsStore: settingsStore))
  }

  var body: some Scene {
    MenuBarExtra("utter", systemImage: "mic") {
      MenuContent()
    }

    // 入力履歴（7章, AC-12）。MVP 外の先行実装で、履歴は既定で無効
    Window("入力履歴", id: InputHistoryWindow.id) {
      InputHistoryWindow(models: historyModels)
    }
    .defaultSize(width: 520, height: 480)
    // 起動時・前回の状態の復元で開かない（履歴の本文を利用者が開くまで画面に出さない）
    .defaultLaunchBehavior(.suppressed)
    .restorationBehavior(.disabled)
  }
}

/// メニューバーのメニュー
private struct MenuContent: View {
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Button("入力履歴…") {
      openWindow(id: InputHistoryWindow.id)
      // メニューバー常駐（Dock に出ない）アプリは、開いたウインドウを前面に出すため自分を前面にする
      NSApplication.shared.activate()
    }
    Divider()
    Button("utter を終了") {
      NSApplication.shared.terminate(nil)
    }
    .keyboardShortcut("q")
  }
}
