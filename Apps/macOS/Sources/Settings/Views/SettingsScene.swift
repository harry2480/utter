import SwiftUI
import UtterAI
import UtterPersistence
import UtterSpeech

/// 設定画面（`Settings` シーン, ⌘,）。
///
/// 設定画面は1つの Settings シーンにまとめ、項目は設計の6つのタブで分ける（API キーは関係するタブの欄に置く）
struct SettingsScene: Scene {
  @State private var model: SettingsModel
  /// 「整形の実行先と費用」タブの Claude API キーの状態（AC-12）
  @State private var apiKeyModel: APIKeySettingsModel
  /// 「認識モデルと省電力」タブの OpenAI API キーの状態（クラウド STT, #188）
  @State private var openAIAPIKeyModel: APIKeySettingsModel
  /// 「整形の実行先と費用」タブの Sign in with ChatGPT の状態（#50）
  @State private var chatGPTAccount: ChatGPTAccountSettingsModel
  /// 「認識モデルと省電力」タブのモデルの取得状態。OS が管理するモデルを使うエンジンを選んだときだけ（PERM-03）
  @State private var speechModel: SpeechModelSettingsModel?
  private let sttEngine: STTEngineKind?

  /// - Parameters:
  ///   - claudeAPIKeyStore: Claude API キーの保存先。整形（`SessionRefinementPipeline`）と同じものを渡す
  ///   - openAIAPIKeyStore: OpenAI API キーの保存先。クラウド STT（`CloudSpeechRecognitionPipeline`）と同じものを渡す
  ///   - chatGPTAccount: Sign in with ChatGPT のアカウント。整形（`SessionRefinementPipeline`）と同じものを渡す
  ///   - database: アプリで1つだけ開くデータベース。推定費用の累計を読む（辞書・入力履歴と共有する）
  ///   - sttEngine: 使っている STT エンジン（`AppComposition.selectedEngine()`）。未選択なら `nil`
  init(
    claudeAPIKeyStore: any APIKeyStore, openAIAPIKeyStore: any APIKeyStore,
    chatGPTAccount: ChatGPTAccountSession, database: AppDatabaseProvider,
    sttEngine: STTEngineKind?
  ) {
    _model = State(
      initialValue: SettingsModel(
        store: AppSettingsStore(defaults: .standard),
        openUsageStore: { MonthlyUsageStore(database: try await database.database()) }))
    _apiKeyModel = State(initialValue: APIKeySettingsModel(store: claudeAPIKeyStore))
    _openAIAPIKeyModel = State(initialValue: APIKeySettingsModel(store: openAIAPIKeyStore))
    // サインインは利用者の操作でだけ始める。作るだけではネットワークを使わない
    _chatGPTAccount = State(
      initialValue: ChatGPTAccountSettingsModel(
        session: chatGPTAccount, server: NetworkLoopbackServer(), browser: WorkspaceBrowser()))
    // 作るだけで、状態の確認はタブを開いたときにする（どちらもネットワークを使わない）
    let modelAssets = STTEngineSetting.makeModelAssets(for: sttEngine)
    _speechModel = State(initialValue: modelAssets.map { SpeechModelSettingsModel(assets: $0) })
    self.sttEngine = sttEngine
  }

  var body: some Scene {
    Settings {
      SettingsView(
        model: model, apiKeyModel: apiKeyModel, openAIAPIKeyModel: openAIAPIKeyModel,
        chatGPTAccount: chatGPTAccount, sttEngine: sttEngine, speechModel: speechModel)
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
