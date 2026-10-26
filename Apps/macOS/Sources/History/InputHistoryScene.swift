import SwiftUI
import UtterPersistence

/// 入力履歴（7章, AC-12）。MVP 外の先行実装で、履歴は既定で無効
struct InputHistoryScene: Scene {
  static let windowID = "inputHistory"

  @State private var models: InputHistoryModelProvider

  init(database: AppDatabaseProvider) {
    // 設定の保存先。履歴への記録を結線するときも同じ保存先を読む（無効化は設定を先に書いてから削除するため）
    let settingsStore = AppSettingsStore(defaults: .standard)
    _models = State(
      initialValue: InputHistoryModelProvider(database: database, settingsStore: settingsStore))
  }

  var body: some Scene {
    Window("入力履歴", id: Self.windowID) {
      InputHistoryWindow(models: models)
    }
    .defaultSize(width: 520, height: 480)
    // 起動時・前回の状態の復元で開かない（履歴の本文を利用者が開くまで画面に出さない）
    .defaultLaunchBehavior(.suppressed)
    .restorationBehavior(.disabled)
  }
}

/// メニューの「入力履歴…」
struct InputHistoryMenuItem: View {
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Button("入力履歴…") {
      openWindow(id: InputHistoryScene.windowID)
      bringToFront()
    }
  }
}
