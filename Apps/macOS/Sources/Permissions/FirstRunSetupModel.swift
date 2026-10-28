import Foundation
import Observation
import UtterCore
import UtterPersistence
import UtterSpeech

/// 初回セットアップの画面の状態（PERM-01〜03, REC-01, REC-02, AI-03, AC-06, #198）。
///
/// 手順は「マイク → アクセシビリティ → 認識モデル → ショートカット → 整形の実行先」の順（`FirstRunSetupStep`）。
/// 手順ごとの状態は今の権限・モデル・設定から求め（`FirstRunSetupEvaluation`）、進み具合だけを保存して次の起動で続きから始める。
///
/// - 権限: 判定と要求は `PermissionOnboardingModel`。要求は画面のボタンからだけ
/// - 認識モデル: 状態の確認と取得は `SpeechModelSettingsModel`（設定画面と同じ）。状態の確認はネットワークを使わず、
///   取得は「取得を開始」のボタンからだけ。エンジンが未設定なら取得のボタンを出さず、未設定であることを示す
/// - ショートカット: 保存は `AppSettingsStore` の録音ショートカットだけを書き換える（ほかの項目は保存先の最新の値のまま）
/// - 整形の実行先: 選んだときだけ保存する。「あとで」は設定を変えない（既定は Local Basic で、送信しない）。
///   クラウドを選んでも、送るかは整形の経路が同意・API キー（またはサインイン）で決める（AC-06）。ここからは送らない
@MainActor
@Observable
final class FirstRunSetupModel {
  /// 権限の状態と要求
  let permissions: PermissionOnboardingModel
  /// 認識モデルの状態と取得。モデルを取得しないエンジン・未設定なら `nil`
  let speechModel: SpeechModelSettingsModel?
  /// 取得するモデルの説明。`speechModel` と同じく、モデルを取得しないエンジン・未設定なら `nil`
  let speechModelDescription: SpeechModelDescription?
  /// 使う STT エンジン。未設定なら `nil`
  let sttEngine: STTEngineKind?

  private(set) var progress: FirstRunSetupProgress
  private(set) var refinementDecision: FirstRunRefinementDecision?
  /// 保存済みの録音ショートカット
  private(set) var recordingShortcut: KeyCombination?
  /// 保存済みの整形の実行先
  private(set) var refinementChoice: RefinementProviderChoice
  /// 直前に記録した組み合わせを割り当てられなかった結果。次の記録・割当で消える
  private(set) var rejectedShortcut: FirstRunShortcutCheck?
  /// 直前の保存に失敗した（書き込めなかった）か
  private(set) var saveFailed = false
  /// 有効なシステムのショートカット。画面を開いたとき・アプリが前面に来たときに取り直す
  private(set) var systemShortcuts: [ShortcutBinding] = []
  private var editModeShortcut: KeyCombination?

  @ObservationIgnored private let store: AppSettingsStore
  @ObservationIgnored private let defaults: FirstRunSetupDefaults
  @ObservationIgnored private let loadSystemShortcuts: @MainActor () -> [ShortcutBinding]
  @ObservationIgnored private let shortcutStatus: @MainActor () -> GlobalShortcutStatus

  /// - Parameters:
  ///   - speechModel: 認識モデルの状態と取得（`STTEngineSetting.makeModelAssets` から作る）。モデルを取得しないなら `nil`
  ///   - sttEngine: 使う STT エンジン（`AppComposition.selectedEngine()`）。未設定なら `nil`
  ///   - store: 設定の保存先。録音ショートカットと整形の実行先だけを書き換える
  ///   - loadSystemShortcuts: 有効なシステムのショートカット（本番は `SystemShortcuts.loadEnabledBindings`）
  ///   - shortcutStatus: 録音ショートカットの登録の結果（本番は `ShortcutCoordinator.status`）
  init(
    permissions: PermissionOnboardingModel, speechModel: SpeechModelSettingsModel?,
    sttEngine: STTEngineKind?, store: AppSettingsStore, defaults: FirstRunSetupDefaults,
    loadSystemShortcuts: @escaping @MainActor () -> [ShortcutBinding],
    shortcutStatus: @escaping @MainActor () -> GlobalShortcutStatus
  ) {
    self.permissions = permissions
    self.speechModel = speechModel
    speechModelDescription = speechModel == nil ? nil : SpeechModelDescription.of(sttEngine)
    self.sttEngine = sttEngine
    self.store = store
    self.defaults = defaults
    self.loadSystemShortcuts = loadSystemShortcuts
    self.shortcutStatus = shortcutStatus
    progress = defaults.progress
    refinementDecision = defaults.refinementDecision
    let settings = store.load()
    recordingShortcut = settings.recordingShortcut
    editModeShortcut = settings.editModeShortcut
    refinementChoice = RefinementProviderChoice(
      engine: settings.refinementEngine, cloudProvider: settings.cloudRefinementProvider)
  }

  // MARK: 状態

  /// 手順の状態
  func state(of step: FirstRunSetupStep) -> FirstRunSetupStepState {
    switch step {
    case .microphone, .accessibility:
      return FirstRunSetupEvaluation.permissionState(
        for: step, onboarding: permissions.onboarding)
    case .speechModel:
      return FirstRunSetupEvaluation.speechModelState(
        engine: sttEngine, hasModelAssets: speechModel != nil,
        availability: speechModel?.availability, isInstalling: speechModel?.isInstalling ?? false)
    case .shortcut:
      return FirstRunSetupEvaluation.shortcutState(
        check: shortcutCheck,
        permissionState: FirstRunSetupEvaluation.permissionState(
          for: .shortcut, onboarding: permissions.onboarding))
    case .refinement:
      return FirstRunSetupEvaluation.refinementState(decision: refinementDecision)
    }
  }

  /// 手順の中に並べる権限の段階
  func permissionSteps(for step: FirstRunSetupStep) -> [PermissionOnboardingStep] {
    FirstRunSetupEvaluation.permissionSteps(for: step, onboarding: permissions.onboarding)
  }

  /// 保存済みの録音ショートカットの重なりの確認の結果
  var shortcutCheck: FirstRunShortcutCheck {
    FirstRunShortcutCheck.evaluate(
      recordingShortcut, editModeShortcut: editModeShortcut, systemShortcuts: systemShortcuts,
      status: shortcutStatus())
  }

  /// 「次へ」で進めるか
  var canAdvance: Bool {
    !progress.isFinished && progress.current != .refinement
      && state(of: progress.current).allowsAdvancing
  }

  // MARK: 操作

  /// 権限・モデル・設定の状態を取り直す。モデルの状態の確認はネットワークを使わず、取得はしない
  func refresh() async {
    permissions.refresh()
    reloadSettings()
    systemShortcuts = loadSystemShortcuts()
    await speechModel?.refresh()
  }

  /// 次の手順へ進む。整形の実行先の手順は「この実行先にする」「あとで」で終える
  func advance() {
    guard canAdvance else { return }
    var progress = self.progress
    guard progress.advance(currentState: state(of: progress.current)) else { return }
    update(progress)
  }

  /// 前の手順へ戻る
  func goBack() {
    var progress = self.progress
    progress.goBack()
    update(progress)
  }

  /// 終えた後に、最初の手順から見直す
  func restart() {
    var progress = self.progress
    progress.restart()
    update(progress)
  }

  /// 利用者の操作で認識モデルを取得する。未取得のときだけ通信する
  func installSpeechModel() async {
    await speechModel?.install()
  }

  /// 記録を始めるときに呼ぶ。直前の割り当てられなかった結果を消す
  func beginRecordingShortcut() {
    rejectedShortcut = nil
  }

  /// 記録した組み合わせを録音ショートカットとして保存する。重なりがあれば保存せず、結果を `rejectedShortcut` に残す
  func assignShortcut(_ combination: KeyCombination) {
    reloadSettings()
    systemShortcuts = loadSystemShortcuts()
    let check = FirstRunShortcutCheck.evaluate(
      combination, editModeShortcut: editModeShortcut, systemShortcuts: systemShortcuts,
      status: .unassigned)
    guard case .available = check else {
      rejectedShortcut = check
      return
    }
    rejectedShortcut = nil
    save { $0.recordingShortcut = combination }
  }

  /// 整形の実行先を保存して、セットアップを終える。選べない選択肢は保存しない
  func chooseRefinement(_ choice: RefinementProviderChoice) {
    guard progress.current == .refinement, let engine = choice.engine else { return }
    let saved = save { settings in
      settings.refinementEngine = engine
      // Local Basic では送信先を変えない（設定画面と同じ）
      if let provider = choice.cloudProvider {
        settings.cloudRefinementProvider = provider
      }
    }
    guard saved else { return }
    finishRefinement(.chosen)
  }

  /// 整形の実行先を「あとで」にして、セットアップを終える。設定は変えない
  func deferRefinement() {
    guard progress.current == .refinement else { return }
    finishRefinement(.deferred)
  }

  // MARK: 内部

  private func finishRefinement(_ decision: FirstRunRefinementDecision) {
    refinementDecision = decision
    defaults.refinementDecision = decision
    var progress = self.progress
    guard progress.advance(currentState: state(of: .refinement)) else { return }
    update(progress)
  }

  private func update(_ progress: FirstRunSetupProgress) {
    guard progress != self.progress else { return }
    self.progress = progress
    defaults.progress = progress
  }

  /// 保存先の最新の設定を読み、この画面で使う値を取り直す
  private func reloadSettings() {
    let settings = store.load()
    recordingShortcut = settings.recordingShortcut
    editModeShortcut = settings.editModeShortcut
    refinementChoice = RefinementProviderChoice(
      engine: settings.refinementEngine, cloudProvider: settings.cloudRefinementProvider)
  }

  /// 保存先の最新の設定に変更を当てて保存する。ほかの画面で変わった項目はそのまま残す。成功したら `true`
  @discardableResult
  private func save(_ change: (inout AppSettings) -> Void) -> Bool {
    var settings = store.load()
    change(&settings)
    do {
      try store.save(settings)
    } catch {
      saveFailed = true
      return false
    }
    saveFailed = false
    reloadSettings()
    return true
  }
}
