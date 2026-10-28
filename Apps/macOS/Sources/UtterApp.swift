import SwiftUI
import UtterAI

/// macOS アプリの起動部（Composition Root）。
///
/// メニューバーに常駐し、Dock には出さない（Info.plist の `LSUIElement`）。
/// 部品の組み立ては `AppComposition`、セッションの進行は `SessionCoordinator` が持つ。
/// 整形（`SessionRefinementPipeline`）は API キーの画面と同じ `claudeAPIKeyStore`、入力履歴の画面と同じ `database` を使う（AC-12）。
/// クラウド STT（`CloudSpeechRecognitionPipeline`, #188）は API キーの画面と同じ `openAIAPIKeyStore` を使う。
/// Sign in with ChatGPT（#50）は、整形と設定画面で同じ `chatGPTAccount` を使う（トークンの更新を1か所で直列にするため）。
///
/// 機能ごとの画面（`Scene`）とメニューの項目は、機能のディレクトリ（`Sources/<機能>/`）に置き、
/// ここと `AppMenu` には1機能1行で並べるだけにする。複数の PR が同じ行を書き換えないようにするため。
/// アプリ全体で1つずつ持つ部品（`AppComposition`）は、ここで持って `.environment` で渡す。
@main
struct UtterApp: App {
  private static let claudeAPIKeyStore = KeychainAPIKeyStore.claude()
  private static let openAIAPIKeyStore = KeychainAPIKeyStore.openAI()
  /// Sign in with ChatGPT のアカウント。作るだけでは Keychain もネットワークも使わない
  private static let chatGPTAccount = ChatGPTAccountSession(
    store: KeychainChatGPTAccountStore.standard())
  /// アプリが使う SQLite データベース。辞書・使用量・入力履歴で1つを共有する
  private static let database = AppDatabaseProvider()

  @State private var composition = AppComposition(
    claudeAPIKeyStore: Self.claudeAPIKeyStore, openAIAPIKeyStore: Self.openAIAPIKeyStore,
    chatGPTAccount: Self.chatGPTAccount, database: Self.database)
  /// 自動更新。appcast URL と公開鍵がビルド設定で与えられていなければ Sparkle を起動しない（既定無効）。
  @State private var updater = SoftwareUpdater(infoDictionary: Bundle.main.infoDictionary ?? [:])

  var body: some Scene {
    MenuBarExtra("utter", systemImage: "mic") {
      AppMenu()
        .environment(composition)
        // 録音ショートカットの登録（`AppComposition` が持つ）。メニューの表示に使う
        .environment(composition.shortcuts)
        .environment(updater)
    }
    // 機能ごとの画面。1機能1行で、関係する機能の近くに足す
    SettingsScene(
      claudeAPIKeyStore: Self.claudeAPIKeyStore, openAIAPIKeyStore: Self.openAIAPIKeyStore,
      chatGPTAccount: Self.chatGPTAccount, database: Self.database,
      sttEngine: composition.sttEngine)
    DictionaryEditorScene(database: Self.database)
    InputHistoryScene(database: Self.database)
    PermissionOnboardingScene(sttEngine: composition.sttEngine, shortcuts: composition.shortcuts)
    ConsentSettingsScene()
  }
}
