import SwiftUI

/// macOS アプリの起動部（Composition Root）。
///
/// メニューバーに常駐し、Dock には出さない（Info.plist の `LSUIElement`）。
/// 部品の組み立ては `AppComposition`、セッションの進行は `SessionCoordinator` が持つ。
///
/// 機能ごとの画面（`Scene`）とメニューの項目は、機能のディレクトリ（`Sources/<機能>/`）に置き、
/// ここと `AppMenu` には1機能1行で並べるだけにする。複数の PR が同じ行を書き換えないようにするため。
/// アプリ全体で1つずつ持つ部品（`AppComposition`）は、ここで持って `.environment` で渡す。
@main
struct UtterApp: App {
  @State private var composition = AppComposition()
  /// アプリが使う SQLite データベース。辞書・使用量・入力履歴で1つを共有する
  @State private var database = AppDatabaseProvider()
  #if DEBUG
    /// Realtime Direct（AC-15, 実験機能）の実機確認用。Debug ビルドにだけ含める
    @State private var realtimeDirectDebug = RealtimeDirectDebugRunner()
    /// Edit Mode（AC-14, v1.1）の Debug 用の組み立て。`EditModeFeature` で有効にしない限り作らず、メニューにも出さない
    @State private var editMode: EditModeDebugController? =
      EditModeFeature.isEnabled() ? EditModeDebugController.make() : nil
  #endif
  /// Claude 整形を結線するときは、同じ `claudeAPIKeyStore` を `ClaudeProvider(apiKeyStore:)` に渡す（AC-12）。
  private static let claudeAPIKeyStore = KeychainAPIKeyStore.claude()

  var body: some Scene {
    MenuBarExtra("utter", systemImage: "mic") {
      menu
        .environment(composition)
        // 録音ショートカットの登録（`AppComposition` が持つ）。メニューの表示に使う
        .environment(composition.shortcuts)
        #if DEBUG
          .environment(realtimeDirectDebug)
        #endif
    }
    // 機能ごとの画面。1機能1行で、関係する機能の近くに足す
    DictionaryEditorScene()
    InputHistoryScene(database: database)
    PermissionOnboardingScene()
    ConsentSettingsScene()
    ClaudeAPIKeySettingsScene(store: Self.claudeAPIKeyStore)
  }

  private var menu: AppMenu {
    #if DEBUG
      return AppMenu(editMode: editMode)
    #else
      return AppMenu()
    #endif
  }
}
