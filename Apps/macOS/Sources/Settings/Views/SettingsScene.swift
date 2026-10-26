import SwiftUI
import UtterPersistence

/// 設定画面（`Settings` シーン, ⌘,）。
///
/// 設定画面は1つの Settings シーンにまとめ、項目はタブで分ける（API キーなどの画面もタブとして足す）
struct SettingsScene: Scene {
  @State private var model = SettingsModel(
    store: AppSettingsStore(defaults: .standard),
    openUsageStore: {
      MonthlyUsageStore(database: try UtterDatabase.open(at: AppDatabaseLocation.url()))
    })

  var body: some Scene {
    Settings {
      SettingsView(model: model)
    }
  }
}

/// メニューの「設定…」
struct SettingsMenuItem: View {
  @Environment(\.openSettings) private var openSettings

  var body: some View {
    // Dock に出ないアプリでは設定画面が前面に来ないため、先にアプリを前面にする
    Button("設定…") {
      bringToFront()
      openSettings()
    }
    .keyboardShortcut(",")
  }
}
