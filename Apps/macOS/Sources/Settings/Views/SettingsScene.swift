import SwiftUI
import UtterAI
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
  /// 「API キー」タブの状態（AC-12）
  @State private var apiKeyModel: APIKeySettingsModel

  /// - Parameter claudeAPIKeyStore: Claude API キーの保存先。
  ///   Claude 整形の `ClaudeProvider(apiKeyStore:)` と同じものを渡す
  init(claudeAPIKeyStore: any APIKeyStore) {
    _apiKeyModel = State(initialValue: APIKeySettingsModel(store: claudeAPIKeyStore))
  }

  var body: some Scene {
    Settings {
      SettingsView(model: model, apiKeyModel: apiKeyModel)
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
