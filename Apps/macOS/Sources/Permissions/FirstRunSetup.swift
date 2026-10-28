import UtterCore
import UtterSpeech

/// 初回セットアップの手順（PERM-01〜03, REC-01, REC-02, AI-03, #198）。並びは表示と進む順。
///
/// 音声認識の許可（使う STT が要するとき）はマイクの手順で、入力監視（修飾キー単独のショートカットのとき）は
/// ショートカットの手順で扱う。どちらも `MacPermissionConfiguration` で要る権限に入れたときだけ出す。
enum FirstRunSetupStep: String, CaseIterable, Identifiable, Hashable, Sendable {
  case microphone
  case accessibility
  case speechModel
  case shortcut
  case refinement

  var id: Self { self }

  /// 次の手順。最後の手順なら `nil`
  var next: FirstRunSetupStep? {
    let steps = Self.allCases
    guard let index = steps.firstIndex(of: self), index + 1 < steps.count else { return nil }
    return steps[index + 1]
  }

  /// 前の手順。最初の手順なら `nil`
  var previous: FirstRunSetupStep? {
    let steps = Self.allCases
    guard let index = steps.firstIndex(of: self), index > 0 else { return nil }
    return steps[index - 1]
  }

  /// この手順で扱う権限。`PermissionOnboarding` の段階のうち、ここに含まれるものを手順の中に並べる
  var permissions: Set<AppPermission> {
    switch self {
    case .microphone: [.microphone, .speechRecognition]
    case .accessibility: [.accessibility]
    case .shortcut: [.inputMonitoring]
    case .speechModel, .refinement: []
    }
  }
}

/// 手順の状態。今の権限・モデル・設定から毎回求め、保存しない（保存するのは進み具合だけ）。
enum FirstRunSetupStepState: Hashable, Sendable {
  /// 済んでいる
  case completed
  /// この構成では要らない
  case notNeeded
  /// OS が進めている（モデルの取得中）。終わりを待たずに次へ進める
  case inProgress
  /// 利用者の操作が要る
  case needsAction
  /// この画面では済ませられない。次へ進める
  case unavailable(FirstRunSetupUnavailableReason)
  /// 利用者が「あとで」を選んだ（整形の実行先）
  case deferred

  /// 「次へ」で進めるか。利用者の操作が要る手順だけは進めない
  var allowsAdvancing: Bool {
    self != .needsAction
  }
}

/// この画面では済ませられない理由。
enum FirstRunSetupUnavailableReason: Hashable, Sendable {
  /// 管理者により制限されている権限がある
  case restrictedByAdministrator
  /// 音声認識のエンジンが未設定（Config/Local.xcconfig の `UTTER_MAC_STT_ENGINE`）
  case speechEngineNotConfigured
  /// この Mac・言語では認識モデルを使えない
  case speechModelUnsupported
}

/// 整形の実行先の手順での利用者の選択。
enum FirstRunRefinementDecision: String, Hashable, Sendable {
  /// 実行先を選んで保存した
  case chosen
  /// 「あとで」で飛ばした。設定は変えない（既定は Local Basic で、送信しない）
  case deferred
}

/// 初回セットアップの進み具合。次の起動で続きから始めるため保存する（`FirstRunSetupDefaults`）。
struct FirstRunSetupProgress: Hashable, Sendable {
  /// 今の手順
  var current: FirstRunSetupStep = .microphone
  /// 最後の手順まで終えたか。終えていなければ次の起動で画面を開く
  var isFinished = false

  /// 今の手順の状態が進めるものなら、次の手順へ進む。最後の手順なら終える。進んだら `true`
  mutating func advance(currentState: FirstRunSetupStepState) -> Bool {
    guard !isFinished, currentState.allowsAdvancing else { return false }
    if let next = current.next {
      current = next
    } else {
      isFinished = true
    }
    return true
  }

  /// 前の手順へ戻る。最初の手順・終えた後は何もしない
  mutating func goBack() {
    guard !isFinished, let previous = current.previous else { return }
    current = previous
  }

  /// 最初の手順からやり直す（終えた後の見直し）
  mutating func restart() {
    current = .microphone
    isFinished = false
  }
}

/// 手順ごとの状態の求め方。OS・設定には触れない純粋な判定。
enum FirstRunSetupEvaluation {
  /// 権限の手順の状態。`PermissionOnboarding` の段階のうち、手順で扱う権限だけを見る
  static func permissionState(
    for step: FirstRunSetupStep, onboarding: PermissionOnboarding
  ) -> FirstRunSetupStepState {
    let steps = permissionSteps(for: step, onboarding: onboarding)
    if steps.isEmpty { return .notNeeded }
    if steps.allSatisfy({ $0.state == .granted }) { return .completed }
    let changeable = steps.contains { item in
      if case .needed(let action, _) = item.state { action != .notChangeableByUser } else { false }
    }
    return changeable ? .needsAction : .unavailable(.restrictedByAdministrator)
  }

  /// 手順の中に並べる権限の段階（要求の順）
  static func permissionSteps(
    for step: FirstRunSetupStep, onboarding: PermissionOnboarding
  ) -> [PermissionOnboardingStep] {
    onboarding.steps.filter { step.permissions.contains($0.permission) }
  }

  /// 認識モデルの手順の状態。
  /// - Parameters:
  ///   - engine: 使う STT エンジン。未設定なら `nil`
  ///   - hasModelAssets: そのエンジンが OS の管理するモデルを取得するか（`STTEngineSetting.makeModelAssets`）
  ///   - availability: 直近に確かめたモデルの状態。まだ確かめていなければ `nil`
  ///   - isInstalling: 取得を要求中か
  static func speechModelState(
    engine: STTEngineKind?, hasModelAssets: Bool,
    availability: UtterSpeech.SpeechModelAvailability?, isInstalling: Bool
  ) -> FirstRunSetupStepState {
    guard engine != nil else { return .unavailable(.speechEngineNotConfigured) }
    guard hasModelAssets else { return .notNeeded }
    if isInstalling { return .inProgress }
    switch availability {
    case nil, .notInstalled: return .needsAction
    case .downloading: return .inProgress
    case .installed: return .completed
    case .unsupported: return .unavailable(.speechModelUnsupported)
    }
  }

  /// ショートカットの手順の状態。重なり・登録の結果と、手順で扱う権限（入力監視）の両方を見る
  static func shortcutState(
    check: FirstRunShortcutCheck, permissionState: FirstRunSetupStepState
  ) -> FirstRunSetupStepState {
    guard case .available = check else { return .needsAction }
    return permissionState == .needsAction ? .needsAction : .completed
  }

  /// 整形の実行先の手順の状態
  static func refinementState(decision: FirstRunRefinementDecision?) -> FirstRunSetupStepState {
    switch decision {
    case .chosen: .completed
    case .deferred: .deferred
    case nil: .needsAction
    }
  }
}

/// 録音ショートカットの重なりの確認の結果（REC-01, REC-02）。
///
/// 有効なシステムのショートカットとの重なりと、登録の結果（他アプリとの競合・権限の不足）を見る。
/// 他のアプリが独自に処理するショートカットは検出できない。
enum FirstRunShortcutCheck: Hashable, Sendable {
  /// 割り当てていない
  case unassigned
  /// 割り当てられない組み合わせ（システムのショートカットと重なる、Esc の予約など）
  case rejected(KeyCombination, ShortcutRecordingIssue)
  /// Edit Mode のショートカットと同じ
  case sameAsEditMode(KeyCombination)
  /// 割当はあるが、登録の結果使えない（他アプリとの競合・権限の不足など）
  case unavailable(GlobalShortcutSetting, GlobalShortcutUnavailableReason)
  /// 重なりは見つからない
  case available(KeyCombination)

  /// - Parameters:
  ///   - combination: 確かめる組み合わせ（保存済みの割当、または記録した組み合わせ）
  ///   - editModeShortcut: 保存済みの Edit Mode のショートカット
  ///   - systemShortcuts: 有効なシステムのショートカット（`SystemShortcuts.loadEnabledBindings`）
  ///   - status: 登録の結果（`ShortcutCoordinator.status`）。保存済みの割当の結果だけを使う
  static func evaluate(
    _ combination: KeyCombination?, editModeShortcut: KeyCombination?,
    systemShortcuts: [ShortcutBinding], status: GlobalShortcutStatus
  ) -> FirstRunShortcutCheck {
    guard let combination else { return .unassigned }
    if let issue = ShortcutRecorder.issue(for: combination, systemShortcuts: systemShortcuts) {
      return .rejected(combination, issue)
    }
    if combination == editModeShortcut {
      return .sameAsEditMode(combination)
    }
    if case .unavailable(let setting, let reason) = status, setting.combination == combination {
      return .unavailable(setting, reason)
    }
    return .available(combination)
  }
}
