import AppKit
import Foundation
import Observation
import UtterAI
import UtterCore
import UtterPersistence
import UtterSpeech

/// アプリ全体で1つずつ持つ部品の組み立て（Composition Root）。
///
/// 録音（`AVAudioEngineRecorder`）→ STT Worker → 整形（`SessionRefinementPipeline`）→ 挿入（`InsertionExecutor`）→ HUD と
/// 入力履歴を `SessionCoordinator` でつなぎ、録音のショートカットとメニューの操作をそこへ渡す。
/// 設定画面でクラウド STT（#188, MVP 外。既定は無効）を選んだセッションは、STT Worker を通さずに
/// `CloudSpeechRecognitionPipeline` が作る `OpenAISpeechRecognizer` で認識する
/// （同意・OpenAI API キー・予算がそろったときだけ）。
/// 起動時の復旧と Edit Mode の指示の認識は、クラウド STT を選んでいても STT Worker を使う（音声をクラウドへ送らない）。
/// 整形と履歴は、設定画面・同意の画面・API キーの画面・辞書・入力履歴の画面と同じ保存先を読む。
/// 録音音声は一時保存し（`TemporaryAudioRetention`）、STT Worker の異常終了で認識をやり直し、
/// 起動時には前回の終了前に残った音声の復旧を尋ねる（`LaunchAudioRecovery`, 7章, AC-10）。
/// 復旧した音声の整形はローカルだけで行い、整形モードは設定画面の保存値を使う（起動時はクラウドへ送らない）。
/// セッションの状態が変わるたびにショートカットへ知らせ、Esc の捕捉（#51 の判定待ちで既定は無効）をセッション中だけ有効にする。
/// 録音の設定（録音ショートカット・録音の操作方式・最大録音時間・入力モード）は起動時に保存値を読み、
/// 設定画面で変わったら次のセッションから使う（`followRecordingSettings`）。
/// 端末の状態（メモリ圧迫・低電力モード・電源）は起動から終了まで監視し、STT Worker へ送る（`DeviceResourceMonitoring`, 6章, AC-11）。
/// 入力モードが Realtime Direct（AC-15, 実験機能・MVP 外。既定は Instant）のセッションは、
/// 挿入と同じ `AccessibilityInsertionTarget` を使う `RealtimeDirectWriter` で確定済みチャンクを書き込む。
/// 許可リスト（`RealtimeDirectAllowlist.launchConfigured()`）にないアプリでは使わない。
/// Edit Mode（AC-14）は録音のセッションと同じ録音・STT Worker・API キー・データベースを使い、`EditModeController` で
/// 録音のセッションと1つずつ調停する。Edit Mode のショートカットは録音とは別のキーで、未割り当て（既定）なら何も登録しない。
@MainActor
@Observable
final class AppComposition {
  let hud: HUDController
  let session: SessionCoordinator
  let shortcuts: ShortcutCoordinator
  /// 起動時の復旧。一時音声の保存先を作れなければ `nil`（保存も復旧もしない）
  let launchRecovery: LaunchAudioRecovery?
  /// 端末の状態の監視（6章, AC-11）。録音・認識の有無に関わらず動かす。
  /// STT Worker の認識器を作らないとき（エンジンが未選択、接続先の Bundle ID が取れない）は、送り先がないため監視もしない（`nil`）
  let resourceMonitoring: DeviceResourceMonitoring?
  /// 使う STT エンジン。未選択なら `nil`（`selectedEngine()`）。設定画面の「音声認識」タブに出す
  let sttEngine: STTEngineKind?
  /// Edit Mode の流れ（AC-14）。メニューのキャンセル・元に戻すに使う
  let editMode: EditModeController
  /// Edit Mode のショートカットの登録（AC-14）。メニューの表示に使う
  let editModeShortcut: EditModeShortcut

  /// - Parameters:
  ///   - claudeAPIKeyStore: Claude API キーの保存先（API キーの画面と同じもの, AC-12）
  ///   - openAIAPIKeyStore: OpenAI API キーの保存先（API キーの画面と同じもの）。クラウド STT（#188）だけが使う
  ///   - database: 辞書・推定費用の累計・入力履歴のデータベース（入力履歴の画面と同じもの）
  init(
    claudeAPIKeyStore: any APIKeyStore, openAIAPIKeyStore: any APIKeyStore,
    database: AppDatabaseProvider
  ) {
    let hud = HUDController(
      presenter: HUDPanelPresenter(),
      scheduler: TaskHUDRefreshScheduler()
    )
    let preview = InsertionPreviewPanel()
    // 挿入と Realtime Direct は、録音開始時に記録した入力対象を同じ AX のアダプターで共有する（INS-01, AC-15）
    let target = AccessibilityInsertionTarget()
    let insertion = InsertionExecutor.system(preview: preview, target: target)
    let engine = Self.selectedEngine()
    self.sttEngine = engine
    // エンジンが選ばれていなければ STT Worker を作らない（SessionCoordinator が「音声認識が設定されていません」を表示する）
    let recognizer = engine.flatMap { STTWorkerComposition.makeRecognizer(engine: $0) }
    let settingsStore = AppSettingsStore(defaults: .standard)
    let openDatabase: @MainActor @Sendable () async throws -> UtterDatabase = {
      try await database.database()
    }
    let audioQueue = TemporaryAudioStoreQueue.applicationStore().map(TemporaryAudioStoreQueue.init)
    let initialSettings = settingsStore.load()
    let sessionSettings = Self.sessionSettings(from: initialSettings)
    // 録音は同時に1つだけのため、録音のセッションと Edit Mode で同じものを使う
    let recorder = AVAudioEngineRecorder()
    let session = SessionCoordinator(
      configuration: sessionSettings.configuration,
      recorder: recorder,
      recognizer: recognizer,
      refiner: SessionRefinementPipeline(
        settingsStore: settingsStore, apiKeyStore: claudeAPIKeyStore, database: openDatabase),
      inputMode: sessionSettings.inputMode,
      inserter: SystemSessionInserter(executor: insertion.executor, inspector: insertion.inspector),
      history: InputHistoryRecorder.standard(database: openDatabase),
      hud: hud,
      deadlineScheduler: TaskHUDRefreshScheduler(),
      audioRetention: audioQueue.map(TemporaryAudioRetention.init),
      recognitionRecovery: recognizer.map(STTWorkerRecognitionRecovery.init),
      cloudRecognition: CloudSpeechRecognitionPipeline(
        settingsStore: settingsStore, apiKeyStore: openAIAPIKeyStore, database: openDatabase),
      realtimeDirect: RealtimeDirectWriter.system(
        target: target, preview: preview, sensitivePolicy: Self.savedSensitivePolicy),
      sensitivePolicy: Self.savedSensitivePolicy)
    self.hud = hud
    self.session = session
    let retentionPolicy = ModelRetentionPolicy.fromSettings(initialSettings)
    let resourceMonitoring = recognizer.flatMap { recognizer in
      retentionPolicy.map {
        STTWorkerComposition.makeResourceMonitoring(for: recognizer, policy: $0)
      }
    }
    self.resourceMonitoring = resourceMonitoring
    resourceMonitoring?.start()
    Self.stopAtTermination(resourceMonitoring)
    Self.followRetentionSetting(resourceMonitoring, from: retentionPolicy)
    let launchRecovery = audioQueue.map {
      LaunchAudioRecovery(
        queue: $0, recognizer: recognizer,
        refinementMode: RefinementMode(initialSettings.refinementMode),
        prompt: AudioRecoveryAlert(), preview: preview, gate: session)
    }
    self.launchRecovery = launchRecovery
    // セッションの保存より先に整理と候補の取得をキューに積む（起動後に録音した音声を候補に含めない）
    launchRecovery?.start()
    let shortcutSetting = GlobalShortcutSetting.fromSettings(initialSettings)
    // 録音と Edit Mode のショートカットは1つの登録者で登録する
    let registrar = CarbonHotKeyRegistrar()
    let shortcuts = ShortcutCoordinator(
      setting: shortcutSetting,
      registrar: registrar,
      currentPhase: { [weak session] in session?.phase ?? .idle },
      perform: { [weak session] command in session?.perform(command) })
    self.shortcuts = shortcuts
    // 認識の完了・自動停止・メニューの操作など、ショートカット以外で状態が変わったときも
    // Esc の捕捉をセッション中だけ有効にする（REC-01）
    session.onPhaseChange = { [weak shortcuts] in shortcuts?.sessionPhaseDidChange() }
    Self.followRecordingSettings(
      session: session, shortcuts: shortcuts,
      from: RecordingSettingsSnapshot(session: sessionSettings, shortcut: shortcutSetting))

    let editMode = Self.makeEditMode(
      session: session, recorder: recorder, recognizer: recognizer,
      settingsStore: settingsStore, apiKeyStore: claudeAPIKeyStore, database: openDatabase,
      preview: preview)
    self.editMode = editMode
    let editModeShortcut = EditModeShortcut(
      registrar: registrar, systemShortcuts: SystemShortcuts.loadEnabledBindings,
      onPress: { [weak editMode] in editMode?.toggle() })
    // 未割り当て（既定）なら何も登録しない
    editModeShortcut.apply(
      initialSettings.editModeShortcut, recordingShortcut: initialSettings.recordingShortcut)
    self.editModeShortcut = editModeShortcut
    Self.followEditModeShortcut(editModeShortcut)
  }

  /// Edit Mode の組み立て（AC-14）。選択範囲の読み取り・置き換えは挿入と同じ AX のアダプター、退避は挿入と同じパネルを使う。
  ///
  /// 送信は `EditModeRequestPipeline` が、整形と同じ設定・同意の画面・API キー・データベースを送るたびに読み直して行う。
  /// 機密入力の判定は、判定のたびに保存済みの除外アプリを読む（7章, AC-12）
  private static func makeEditMode(
    session: SessionCoordinator, recorder: any AudioRecorder,
    recognizer: (any SpeechRecognizer)?, settingsStore: AppSettingsStore,
    apiKeyStore: any APIKeyStore,
    database: @escaping @MainActor () async throws -> UtterDatabase,
    preview: InsertionPreviewPanel
  ) -> EditModeController {
    let target = AccessibilityInsertionTarget()
    let panel = EditModePanel(fallback: preview)
    let coordinator = EditModeCoordinator(
      inspector: target,
      field: target,
      permissions: SystemInsertionPermissions(),
      presenter: panel,
      clock: ContinuousInsertionClock(),
      sender: EditModeRequestPipeline(
        settingsStore: settingsStore, apiKeyStore: apiKeyStore, database: database),
      sensitivePolicy: savedSensitivePolicy)
    let controller = EditModeController(
      coordinator: coordinator, recorder: recorder, recognizer: recognizer, gate: session,
      presenter: panel)
    panel.onCommit = { [weak controller] in
      guard let controller else { return }
      Task { await controller.commit() }
    }
    panel.onCancel = { [weak controller] in controller?.cancel() }
    return controller
  }

  /// 機密入力の判定。保存済みの除外アプリを呼ぶたびに読む（7章, AC-12）
  private static func savedSensitivePolicy() -> SensitiveInputPolicy {
    let excludedApps = AppSettingsStore(defaults: .standard).load().excludedApps
    return SensitiveInputPolicy(excludedApps: Set(excludedApps))
  }

  /// 設定画面で Edit Mode のショートカット（または録音ショートカット）が変わったら登録し直す（AC-14）。
  ///
  /// 録音の設定と同じく UserDefaults の変更の通知で読み直す。同じ割当なら登録し直さない（`EditModeShortcut.apply`）。
  /// 押下は始める・止めるだけのため、Edit の途中で登録し直しても進行中の Edit は変えない
  private static func followEditModeShortcut(_ shortcut: EditModeShortcut) {
    // アプリの終了まで登録したままにするため、戻り値（登録の解除に使う）は持たない
    _ = NotificationCenter.default.addObserver(
      forName: UserDefaults.didChangeNotification, object: nil, queue: .main
    ) { [weak shortcut] _ in
      MainActor.assumeIsolated {
        guard let shortcut else { return }
        let settings = AppSettingsStore(defaults: .standard).load()
        shortcut.apply(settings.editModeShortcut, recordingShortcut: settings.recordingShortcut)
      }
    }
  }

  /// アプリの終了時に端末の状態の監視をやめる（通知の登録を残さない）
  private static func stopAtTermination(_ monitoring: DeviceResourceMonitoring?) {
    guard let monitoring else { return }
    // アプリの終了まで登録したままにするため、戻り値（登録の解除に使う）は持たない
    _ = NotificationCenter.default.addObserver(
      forName: NSApplication.willTerminateNotification, object: nil, queue: .main
    ) { _ in
      MainActor.assumeIsolated { monitoring.stop() }
    }
  }

  /// 設定画面で保持モード（6章）が変わったら、STT Worker へ送る方針を送り直す。
  ///
  /// 設定は UserDefaults に保存されるため、その変更の通知で読み直し、方針が変わったときだけ送る
  private static func followRetentionSetting(
    _ monitoring: DeviceResourceMonitoring?, from initial: ModelRetentionPolicy?
  ) {
    guard let monitoring else { return }
    let tracker = ChangeTracker(current: initial)
    // アプリの終了まで登録したままにするため、戻り値（登録の解除に使う）は持たない
    _ = NotificationCenter.default.addObserver(
      forName: UserDefaults.didChangeNotification, object: nil, queue: .main
    ) { _ in
      MainActor.assumeIsolated {
        let settings = AppSettingsStore(defaults: .standard).load()
        guard let policy = ModelRetentionPolicy.fromSettings(settings),
          tracker.replace(with: policy)
        else { return }
        monitoring.updatePolicy(policy)
      }
    }
  }

  /// 設定画面で録音の設定が変わったら、セッションとショートカットへ送り直す（REC-01, REC-02, REC-05, 2.2節）。
  ///
  /// 保持モードと同じく UserDefaults の変更の通知で読み直し、値が変わったときだけ送る。
  /// どちらも進行中のセッションは変えず、セッションは次の開始時から、ショートカットは待機に戻ってから使う
  private static func followRecordingSettings(
    session: SessionCoordinator, shortcuts: ShortcutCoordinator,
    from initial: RecordingSettingsSnapshot
  ) {
    let tracker = ChangeTracker(current: initial)
    // アプリの終了まで登録したままにするため、戻り値（登録の解除に使う）は持たない
    _ = NotificationCenter.default.addObserver(
      forName: UserDefaults.didChangeNotification, object: nil, queue: .main
    ) { [weak session, weak shortcuts] _ in
      MainActor.assumeIsolated {
        guard let session, let shortcuts else { return }
        let settings = AppSettingsStore(defaults: .standard).load()
        let snapshot = RecordingSettingsSnapshot(
          session: Self.sessionSettings(from: settings),
          shortcut: GlobalShortcutSetting.fromSettings(settings))
        guard let previous = tracker.value, tracker.replace(with: snapshot) else { return }
        if snapshot.session != previous.session {
          session.useSettings(snapshot.session)
        }
        if snapshot.shortcut != previous.shortcut {
          shortcuts.updateSetting(snapshot.shortcut)
        }
      }
    }
  }

  /// セッションに使う録音・入力の設定。保存された設定から作る（`SessionSettings.fromSettings`）。
  ///
  /// Debug ビルドに限り、入力モードは起動引数が保存値より優先する:
  /// `-UtterDebugInputMode realtimePreview`（または `instant` / `realtimeDirect`）
  private static func sessionSettings(from settings: AppSettings) -> SessionSettings {
    var result = SessionSettings.fromSettings(settings)
    #if DEBUG
      switch debugArgument("UtterDebugInputMode") {
      case "realtimePreview": result.inputMode = .realtimePreview
      case "instant": result.inputMode = .instant
      case "realtimeDirect": result.inputMode = .realtimeDirect
      default: break
      }
    #endif
    return result
  }

  /// 使う STT エンジン。既定のエンジンは Phase 0 の判定（11章）待ちのため、構成で明示的に選ばない限り `nil`。
  ///
  /// Config/Local.xcconfig の `UTTER_MAC_STT_ENGINE`（Info.plist の `UtterSTTEngine`）で選ぶ。
  /// Release で受け付けるのは `speechAnalyzer` だけで、知らない値・空の値は `nil`（判定は `STTEngineSetting`）。
  /// Debug ビルドに限り、起動引数がビルド設定より優先し、開発用の `stub`（Worker の往復の確認用）も選べる:
  /// `open utter.app --args -UtterDebugSTTEngine speechAnalyzer`
  static func selectedEngine() -> STTEngineKind? {
    #if DEBUG
      let launchArgument = debugArgument("UtterDebugSTTEngine")
      let allowsStub = true
    #else
      let launchArgument: String? = nil
      let allowsStub = false
    #endif
    let value = Bundle.main.object(forInfoDictionaryKey: STTEngineSetting.infoPlistKey) as? String
    return STTEngineSetting.resolve(
      buildSetting: value, launchArgument: launchArgument, allowsStub: allowsStub)
  }

  #if DEBUG
    /// 起動引数だけを見る（defaults write で保存した値は読まない）
    private static func debugArgument(_ key: String) -> String? {
      UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)[key] as? String
    }
  #endif
}

/// 直前に送った設定の値（STT Worker へ送った保持の方針、セッションとショートカットへ送った録音の設定）。
/// 同じ値を送り直さないために持つ
@MainActor
private final class ChangeTracker<Value: Equatable> {
  private(set) var value: Value?

  init(current: Value?) {
    value = current
  }

  /// 値が変わったら置き換えて `true`。同じなら `false`
  func replace(with newValue: Value) -> Bool {
    guard newValue != value else { return false }
    value = newValue
    return true
  }
}

/// セッションとショートカットへ送った録音の設定。設定画面の保存のたびに比べ、変わった側だけへ送る
private struct RecordingSettingsSnapshot: Equatable {
  let session: SessionSettings
  let shortcut: GlobalShortcutSetting?
}
