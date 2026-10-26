import Foundation
import Observation
import UtterAI
import UtterCore
import UtterPersistence
import UtterSpeech

/// アプリ全体で1つずつ持つ部品の組み立て（Composition Root）。
///
/// 録音（`AVAudioEngineRecorder`）→ STT Worker → ローカル整形 → 挿入（`InsertionExecutor`）→ HUD を
/// `SessionCoordinator` でつなぎ、録音のショートカットとメニューの操作をそこへ渡す。
/// 録音音声は一時保存し（`TemporaryAudioRetention`）、STT Worker の異常終了で認識をやり直し、
/// 起動時には前回の終了前に残った音声の復旧を尋ねる（`LaunchAudioRecovery`, 7章, AC-10）。
@MainActor
@Observable
final class AppComposition {
  let hud: HUDController
  let session: SessionCoordinator
  let shortcuts: ShortcutCoordinator
  /// 起動時の復旧。一時音声の保存先を作れなければ `nil`（保存も復旧もしない）
  let launchRecovery: LaunchAudioRecovery?

  init() {
    let hud = HUDController(
      presenter: HUDPanelPresenter(),
      scheduler: TaskHUDRefreshScheduler()
    )
    let preview = InsertionPreviewPanel()
    let insertion = InsertionExecutor.system(preview: preview)
    let engine = Self.selectedEngine()
    // エンジンが選ばれていなければ STT Worker を作らない（SessionCoordinator が「音声認識が設定されていません」を表示する）
    let recognizer = engine.flatMap { STTWorkerComposition.makeRecognizer(engine: $0) }
    let refinementMode = Self.refinementMode()
    let audioQueue = TemporaryAudioStoreQueue.applicationStore().map(TemporaryAudioStoreQueue.init)
    let session = SessionCoordinator(
      recorder: AVAudioEngineRecorder(),
      recognizer: recognizer,
      refinementMode: refinementMode,
      inserter: SystemSessionInserter(executor: insertion.executor, inspector: insertion.inspector),
      hud: hud,
      deadlineScheduler: TaskHUDRefreshScheduler(),
      audioRetention: audioQueue.map(TemporaryAudioRetention.init),
      recognitionRecovery: recognizer.map(STTWorkerRecognitionRecovery.init))
    self.hud = hud
    self.session = session
    launchRecovery = audioQueue.map {
      LaunchAudioRecovery(
        queue: $0, recognizer: recognizer, refinementMode: refinementMode,
        prompt: AudioRecoveryAlert(), preview: preview, gate: session)
    }
    // セッションの保存より先に整理と候補の取得をキューに積む（起動後に録音した音声を候補に含めない）
    launchRecovery?.start()
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
