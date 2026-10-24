import Foundation
import UtterAI
import UtterCore
import UtterPersistence
import UtterSpeech

/// アプリ全体で1つずつ持つ部品の組み立て（Composition Root）。
///
/// 録音（`AVAudioEngineRecorder`）→ STT Worker → 整形（`SessionRefinementPipeline`）→ 挿入（`InsertionExecutor`）→ HUD と
/// 入力履歴を `SessionCoordinator` でつなぎ、録音のショートカットとメニューの操作をそこへ渡す。
/// 整形と履歴は、設定画面・同意の画面・API キーの画面・辞書・入力履歴の画面と同じ保存先を読む。
@MainActor
final class AppComposition {
  let hud: HUDController
  let session: SessionCoordinator
  let shortcuts: ShortcutCoordinator

  /// - Parameters:
  ///   - claudeAPIKeyStore: Claude API キーの保存先（API キーの画面と同じもの, AC-12）
  ///   - database: 辞書・推定費用の累計・入力履歴のデータベース（入力履歴の画面と同じもの）
  init(claudeAPIKeyStore: any APIKeyStore, database: AppDatabaseProvider) {
    let hud = HUDController(
      presenter: HUDPanelPresenter(),
      scheduler: TaskHUDRefreshScheduler()
    )
    let insertion = InsertionExecutor.system(preview: InsertionPreviewPanel())
    let engine = Self.selectedEngine()
    // エンジンが選ばれていなければ STT Worker を作らない（SessionCoordinator が「音声認識が設定されていません」を表示する）
    let recognizer = engine.flatMap { STTWorkerComposition.makeRecognizer(engine: $0) }
    let settingsStore = AppSettingsStore(defaults: .standard)
    let openDatabase: @MainActor @Sendable () async throws -> UtterDatabase = {
      try await database.database()
    }
    let session = SessionCoordinator(
      recorder: AVAudioEngineRecorder(),
      recognizer: recognizer,
      refiner: SessionRefinementPipeline(
        settingsStore: settingsStore, apiKeyStore: claudeAPIKeyStore, database: openDatabase),
      inserter: SystemSessionInserter(executor: insertion.executor, inspector: insertion.inspector),
      history: InputHistoryRecorder.standard(database: openDatabase),
      hud: hud,
      deadlineScheduler: TaskHUDRefreshScheduler())
    self.hud = hud
    self.session = session
    shortcuts = ShortcutCoordinator(
      currentPhase: { [weak session] in session?.phase ?? .idle },
      perform: { [weak session] command in session?.perform(command) })
  }

  /// 使う STT エンジン。既定のエンジンは Phase 0 の判定（11章）待ちのため、構成で明示的に選ばない限り `nil`。
  ///
  /// 設定画面（版2設定）が入るまでは、Debug ビルドに限り起動引数で選べる:
  /// `open utter.app --args -UtterDebugSTTEngine speechAnalyzer`（`stub` は Worker の往復の確認用）
  private static func selectedEngine() -> STTEngineKind? {
    #if DEBUG
      if let raw = debugArgument("UtterDebugSTTEngine"), let engine = STTEngineKind(rawValue: raw) {
        return engine
      }
    #endif
    return STTWorkerComposition.selectedEngine
  }

  #if DEBUG
    /// 起動引数だけを見る（defaults write で保存した値は読まない）
    private static func debugArgument(_ key: String) -> String? {
      UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)[key] as? String
    }
  #endif
}
