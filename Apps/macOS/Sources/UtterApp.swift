import AppKit
import SwiftUI
import UtterCore
import UtterPersistence

/// macOS アプリの起動部（Composition Root）。
///
/// メニューバーに常駐し、Dock には出さない（Info.plist の `LSUIElement`）。
/// 録音・ホットキー・HUD・挿入は Phase 0 の判定後に、ここで本番実装と Stub を組み立てて結線する。
/// 整形の予算判定を結線するときは、`CloudCostBridge.makeBudgetGuard` に同じデータベースの `MonthlyUsageStore` を渡す（AI-05）。
@main
struct UtterApp: App {
  @State private var settings = SettingsModel(
    store: AppSettingsStore(defaults: .standard),
    openUsageStore: {
      MonthlyUsageStore(database: try UtterDatabase.open(at: AppDatabaseLocation.url()))
    })

  var body: some Scene {
    MenuBarExtra("utter", systemImage: "mic") {
      SettingsMenuButton()
      Divider()
      Button("utter を終了") {
        NSApplication.shared.terminate(nil)
      }
      .keyboardShortcut("q")
    }
    // 設定画面は1つの Settings シーンにまとめ、項目はタブで分ける（API キーなどの画面もタブとして足す）
    Settings {
      SettingsView(model: settings)
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
