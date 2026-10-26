import SwiftUI

/// macOS アプリの起動部（Composition Root）。
///
/// メニューバーに常駐し、Dock には出さない（Info.plist の `LSUIElement`）。
/// 部品の組み立ては `AppComposition`、セッションの進行は `SessionCoordinator` が持つ。
/// 整形（`SessionRefinementPipeline`）は API キーの画面と同じ `claudeAPIKeyStore`、入力履歴の画面と同じ `database` を使う（AC-12）。
///
/// 機能ごとの画面（`Scene`）とメニューの項目は、機能のディレクトリ（`Sources/<機能>/`）に置き、
/// ここと `AppMenu` には1機能1行で並べるだけにする。複数の PR が同じ行を書き換えないようにするため。
/// アプリ全体で1つずつ持つ部品（`AppComposition`）は、ここで持って `.environment` で渡す。
@main
struct UtterApp: App {
  private static let claudeAPIKeyStore = KeychainAPIKeyStore.claude()
  /// アプリが使う SQLite データベース。辞書・使用量・入力履歴で1つを共有する
  private static let database = AppDatabaseProvider()

  @State private var composition = AppComposition(
    claudeAPIKeyStore: Self.claudeAPIKeyStore, database: Self.database)

  var body: some Scene {
    MenuBarExtra("utter", systemImage: "mic") {
      AppMenu()
        .environment(composition)
        // 録音ショートカットの登録（`AppComposition` が持つ）。メニューの表示に使う
        .environment(composition.shortcuts)
    }
    // 機能ごとの画面。1機能1行で、関係する機能の近くに足す
    SettingsScene(claudeAPIKeyStore: Self.claudeAPIKeyStore)
    DictionaryEditorScene()
    InputHistoryScene(database: Self.database)
    ConsentSettingsScene()
  }
}
