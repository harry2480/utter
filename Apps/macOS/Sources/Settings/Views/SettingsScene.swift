import SwiftUI
import UtterAI
import UtterPersistence

/// 設定画面（`Settings` シーン, ⌘,）。
///
/// 設定画面は1つの Settings シーンにまとめ、項目はタブで分ける（API キーなどの画面もタブとして足す）
struct SettingsScene: Scene {
  @State private var model: SettingsModel
  /// 「API キー」タブの状態（AC-12）
  @State private var apiKeyModel: APIKeySettingsModel

  /// - Parameters:
  ///   - claudeAPIKeyStore: Claude API キーの保存先。整形（`SessionRefinementPipeline`）と同じものを渡す
  ///   - database: アプリで1つだけ開くデータベース。推定費用の累計を読む（辞書・入力履歴と共有する）
  init(claudeAPIKeyStore: any APIKeyStore, database: AppDatabaseProvider) {
    _model = State(
      initialValue: SettingsModel(
        store: AppSettingsStore(defaults: .standard),
        openUsageStore: { MonthlyUsageStore(database: try await database.database()) }))
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
