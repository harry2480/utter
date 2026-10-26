import UtterPersistence

/// 入力履歴の画面の状態をアプリ全体で1つだけ作って共有する。
///
/// ウインドウを閉じても途中の操作（無効化の削除など）は続き、開き直した後の操作はその完了を待つ必要があるため、
/// ウインドウごとに作り直さない（`InputHistoryScreenModel`）。
@MainActor
final class InputHistoryModelProvider {
  private let database: AppDatabaseProvider
  private let settingsStore: AppSettingsStore
  private var model: InputHistoryScreenModel?

  init(database: AppDatabaseProvider, settingsStore: AppSettingsStore) {
    self.database = database
    self.settingsStore = settingsStore
  }

  func screenModel() async throws -> InputHistoryScreenModel {
    if let model { return model }
    let historyStore = InputHistoryStore(database: try await database.database())
    // データベースを開くのを待つ間に、ほかの呼び出しが作っていればそれを使う
    if let model { return model }
    let model = InputHistoryScreenModel(settingsStore: settingsStore, historyStore: historyStore)
    self.model = model
    return model
  }
}
