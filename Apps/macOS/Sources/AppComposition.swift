import Foundation
import Observation
import UtterAI
import UtterCore
import UtterSpeech

/// アプリ全体で1つずつ持つ部品の組み立て（Composition Root）。
///
/// 録音（`AVAudioEngineRecorder`）→ STT Worker → ローカル整形 → 挿入（`InsertionExecutor`）→ HUD を
/// `SessionCoordinator` でつなぎ、録音のショートカットとメニューの操作をそこへ渡す。
/// `UtterApp` が1つだけ持ち、メニューの項目と画面へ `.environment` で渡す。
@MainActor
@Observable
final class AppComposition {
  let hud: HUDController
  let session: SessionCoordinator
  let shortcuts: ShortcutCoordinator

  init() {
    let hud = HUDController(
      presenter: HUDPanelPresenter(),
      scheduler: TaskHUDRefreshScheduler()
    )
    let insertion = InsertionExecutor.system(preview: InsertionPreviewPanel())
    let engine = Self.selectedEngine()
    // エンジンが選ばれていなければ STT Worker を作らない（SessionCoordinator が「音声認識が設定されていません」を表示する）
    let recognizer = engine.flatMap { STTWorkerComposition.makeRecognizer(engine: $0) }
    let session = SessionCoordinator(
      recorder: AVAudioEngineRecorder(),
      recognizer: recognizer,
      refinementMode: Self.refinementMode(),
      inserter: SystemSessionInserter(executor: insertion.executor, inspector: insertion.inspector),
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

  /// 整形モード（TXT-01）。設定（版2設定）が入るまでは、STT の結果を変えない Raw を使う。
  ///
  /// Debug ビルドに限り起動引数で選べる: `-UtterDebugRefinementMode natural`（`raw` / `natural` / `structured`）
  private static func refinementMode() -> RefinementMode {
    #if DEBUG
      switch debugArgument("UtterDebugRefinementMode") {
      case "natural": return .natural
      case "structured": return .structured
      default: break
      }
    #endif
    return .raw
  }

  #if DEBUG
    /// 起動引数だけを見る（defaults write で保存した値は読まない）
    private static func debugArgument(_ key: String) -> String? {
      UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)[key] as? String
    }
  #endif
}
