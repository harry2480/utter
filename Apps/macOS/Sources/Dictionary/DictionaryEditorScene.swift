import SwiftUI
import UtterPersistence

/// 辞書の編集画面（TXT-03, AC-07）。
struct DictionaryEditorScene: Scene {
  static let windowID = "dictionary"

  @State private var model: DictionaryEditorModel

  /// - Parameter database: アプリで1つだけ開くデータベース（入力履歴・推定費用の累計と共有する）
  init(database: AppDatabaseProvider) {
    _model = State(
      initialValue: DictionaryEditorModel {
        DictionaryStore(database: try await database.database())
      })
  }

  var body: some Scene {
    Window("辞書", id: Self.windowID) {
      DictionaryEditorView(model: model)
    }
  }
}

/// メニューの「辞書を編集…」
struct DictionaryEditorMenuItem: View {
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Button("辞書を編集…") {
      openWindow(id: DictionaryEditorScene.windowID)
      bringToFront()
    }
  }
}
