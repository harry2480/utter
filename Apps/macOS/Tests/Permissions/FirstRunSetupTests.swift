import Testing
import UtterCore
import UtterSpeech

/// 初回セットアップの手順・状態・進み具合の判定（#198）
struct FirstRunSetupTests {
  private let shortcut = KeyCombination(key: .space, modifiers: [.option, .command])

  // MARK: 手順と進み具合

  @Test("PERM-03: 手順はマイク → アクセシビリティ → 認識モデル → ショートカット → 整形の実行先の順")
  func stepOrder() {
    #expect(
      FirstRunSetupStep.allCases == [
        .microphone, .accessibility, .speechModel, .shortcut, .refinement,
      ])
    #expect(FirstRunSetupStep.microphone.previous == nil)
    #expect(FirstRunSetupStep.microphone.next == .accessibility)
    #expect(FirstRunSetupStep.refinement.next == nil)
  }

  @Test("PERM-03: 利用者の操作が要る手順からは進まない")
  func doesNotAdvanceWhenActionNeeded() {
    var progress = FirstRunSetupProgress()

    let advanced = progress.advance(currentState: .needsAction)

    #expect(!advanced)
    #expect(progress == FirstRunSetupProgress(current: .microphone, isFinished: false))
  }

  @Test(
    "PERM-03: 済んだ・要らない・取得中・ここで設定できない・あとでの手順からは次へ進める",
    arguments: [
      FirstRunSetupStepState.completed, .notNeeded, .inProgress,
      .unavailable(.restrictedByAdministrator), .deferred,
    ])
  func advancesWhenSettled(state: FirstRunSetupStepState) {
    var progress = FirstRunSetupProgress()

    let advanced = progress.advance(currentState: state)

    #expect(advanced)
    #expect(progress.current == .accessibility)
  }

  @Test("PERM-03: 最後の手順から進むと終わり、終えた後は進まず戻らない")
  func finishesAfterLastStep() {
    var progress = FirstRunSetupProgress(current: .refinement, isFinished: false)

    let finished = progress.advance(currentState: .deferred)
    let again = progress.advance(currentState: .completed)
    progress.goBack()

    #expect(finished)
    #expect(!again)
    #expect(progress == FirstRunSetupProgress(current: .refinement, isFinished: true))
  }

  @Test("PERM-03: 戻ると前の手順になり、見直すと最初の手順から始める")
  func goesBackAndRestarts() {
    var progress = FirstRunSetupProgress(current: .shortcut, isFinished: false)
    progress.goBack()
    #expect(progress.current == .speechModel)

    progress = FirstRunSetupProgress(current: .refinement, isFinished: true)
    progress.restart()
    #expect(progress == FirstRunSetupProgress(current: .microphone, isFinished: false))
  }

  // MARK: 権限の手順

  private func makeOnboarding(_ statuses: [AppPermission: PermissionStatus])
    -> PermissionOnboarding
  {
    let configuration = MacPermissionConfiguration.phase0Pending
    return PermissionOnboarding(
      features: configuration.features, permissions: PermissionSnapshot(statuses),
      requirements: configuration.requirements)
  }

  @Test("PERM-01: 判定前の構成では、マイクとアクセシビリティを求め、貼り付け・キー入力の経路は確認中にする")
  func phase0PendingRequiresMicrophoneAndAccessibility() {
    let onboarding = makeOnboarding([:])

    #expect(onboarding.steps.map(\.permission) == [.microphone, .accessibility])
    #expect(onboarding.undecidedFeatures == [.insertion(.pasteboard), .insertion(.keyEvents)])
  }

  @Test("PERM-01: 権限の手順は、手順で扱う権限の状態だけで決まる")
  func permissionStateUsesOwnPermissions() {
    let onboarding = makeOnboarding([.microphone: .granted, .accessibility: .denied])

    #expect(
      FirstRunSetupEvaluation.permissionState(for: .microphone, onboarding: onboarding)
        == .completed)
    #expect(
      FirstRunSetupEvaluation.permissionState(for: .accessibility, onboarding: onboarding)
        == .needsAction)
    #expect(
      FirstRunSetupEvaluation.permissionSteps(for: .accessibility, onboarding: onboarding).map(
        \.permission) == [.accessibility])
  }

  @Test("PERM-01: 入力監視は修飾キー単独を使わない構成では求めない")
  func inputMonitoringNotNeededWithoutModifierOnly() {
    let onboarding = makeOnboarding([:])

    #expect(
      FirstRunSetupEvaluation.permissionState(for: .shortcut, onboarding: onboarding)
        == .notNeeded)
  }

  @Test("PERM-01: 修飾キー単独を使う構成では、ショートカットの手順で入力監視を求める")
  func inputMonitoringNeededForModifierOnly() {
    let onboarding = PermissionOnboarding(
      features: [.recording, .modifierOnlyShortcut], permissions: PermissionSnapshot(),
      requirements: PermissionRequirements(
        transcription: [], insertionRoutes: [:], modifierOnlyShortcut: [.inputMonitoring],
        escapeCancel: []))

    #expect(
      FirstRunSetupEvaluation.permissionSteps(for: .shortcut, onboarding: onboarding).map(
        \.permission) == [.inputMonitoring])
    #expect(
      FirstRunSetupEvaluation.permissionSteps(for: .microphone, onboarding: onboarding).map(
        \.permission) == [.microphone])
  }

  @Test("PERM-01: 使う STT が音声認識の許可を要するときは、マイクの手順で求める")
  func speechRecognitionInMicrophoneStep() {
    let onboarding = PermissionOnboarding(
      features: [.recording], permissions: PermissionSnapshot([.microphone: .granted]),
      requirements: PermissionRequirements(
        transcription: [.speechRecognition], insertionRoutes: [:], modifierOnlyShortcut: [],
        escapeCancel: []))

    #expect(
      FirstRunSetupEvaluation.permissionSteps(for: .microphone, onboarding: onboarding).map(
        \.permission) == [.microphone, .speechRecognition])
    #expect(
      FirstRunSetupEvaluation.permissionState(for: .microphone, onboarding: onboarding)
        == .needsAction)
  }

  @Test("PERM-01: 管理者により制限されている権限だけが残るなら、ここでは設定できないとして進める")
  func restrictedPermissionIsUnavailable() {
    let onboarding = makeOnboarding([.microphone: .restricted])

    #expect(
      FirstRunSetupEvaluation.permissionState(for: .microphone, onboarding: onboarding)
        == .unavailable(.restrictedByAdministrator))
  }

  // MARK: 認識モデルの手順

  @Test("PERM-03: エンジンが未設定なら、モデルの手順は未設定であることを示して進める")
  func speechModelWithoutEngine() {
    let state = FirstRunSetupEvaluation.speechModelState(
      engine: nil, hasModelAssets: false, availability: nil, isInstalling: false)

    #expect(state == .unavailable(.speechEngineNotConfigured))
    #expect(state.allowsAdvancing)
  }

  @Test("PERM-03: モデルを取得しないエンジンなら、モデルの手順は要らない")
  func speechModelNotNeeded() {
    #expect(
      FirstRunSetupEvaluation.speechModelState(
        engine: .stub, hasModelAssets: false, availability: nil, isInstalling: false)
        == .notNeeded)
  }

  @Test(
    "PERM-03: モデルの状態から手順の状態を決める",
    arguments: [
      (nil, false, FirstRunSetupStepState.needsAction),
      (.notInstalled, false, .needsAction),
      (.notInstalled, true, .inProgress),
      (.downloading, false, .inProgress),
      (.installed, false, .completed),
      (.unsupported, false, .unavailable(.speechModelUnsupported)),
    ] as [(UtterSpeech.SpeechModelAvailability?, Bool, FirstRunSetupStepState)])
  func speechModelState(
    availability: UtterSpeech.SpeechModelAvailability?, isInstalling: Bool,
    expected: FirstRunSetupStepState
  ) {
    #expect(
      FirstRunSetupEvaluation.speechModelState(
        engine: .speechAnalyzer, hasModelAssets: true, availability: availability,
        isInstalling: isInstalling) == expected)
  }

  @Test("PERM-03: SpeechAnalyzer のモデルだけ、モデル名・取得元・サイズ・取得後の確認を示す")
  func speechModelDescription() throws {
    let description = try #require(SpeechModelDescription.of(.speechAnalyzer))

    #expect(description.name.contains("ja-JP"))
    #expect(!description.source.isEmpty)
    #expect(!description.size.isEmpty)
    #expect(!description.integrity.isEmpty)
    #expect(SpeechModelDescription.of(nil) == nil)
    #expect(SpeechModelDescription.of(.whisperKit) == nil)
    #expect(SpeechModelDescription.of(.stub) == nil)
  }

  // MARK: ショートカットの手順

  @Test("REC-01: 割り当てていなければ、ショートカットの手順は操作が要る")
  func unassignedShortcut() {
    let check = FirstRunShortcutCheck.evaluate(
      nil, editModeShortcut: nil, systemShortcuts: [], status: .unassigned)

    #expect(check == .unassigned)
    #expect(
      FirstRunSetupEvaluation.shortcutState(check: check, permissionState: .notNeeded)
        == .needsAction)
  }

  @Test("REC-02: 有効なシステムのショートカットと重なれば、重なりとして示す")
  func systemConflict() {
    let system = [ShortcutBinding(id: "system.index.0", combination: shortcut)]

    #expect(
      FirstRunShortcutCheck.evaluate(
        shortcut, editModeShortcut: nil, systemShortcuts: system, status: .unassigned)
        == .rejected(shortcut, .conflictsWithSystemShortcut))
  }

  @Test("AC-14: Edit Mode のショートカットと同じなら、重なりとして示す")
  func sameAsEditMode() {
    #expect(
      FirstRunShortcutCheck.evaluate(
        shortcut, editModeShortcut: shortcut, systemShortcuts: [], status: .unassigned)
        == .sameAsEditMode(shortcut))
  }

  @Test("REC-02: 登録に失敗した（他アプリと重なる）ときは、その結果を示す")
  func registrationFailure() {
    let setting = GlobalShortcutSetting(combination: shortcut, mode: .toggle)
    let status = GlobalShortcutStatus.unavailable(
      setting, .registrationFailed(.alreadyRegistered))

    #expect(
      FirstRunShortcutCheck.evaluate(
        shortcut, editModeShortcut: nil, systemShortcuts: [], status: status)
        == .unavailable(setting, .registrationFailed(.alreadyRegistered)))
  }

  @Test("REC-02: 別の組み合わせの登録の結果は使わない")
  func ignoresStatusOfOtherCombination() {
    let other = KeyCombination(key: .space, modifiers: [.control, .option])
    let status = GlobalShortcutStatus.unavailable(
      GlobalShortcutSetting(combination: other, mode: .toggle),
      .registrationFailed(.alreadyRegistered))

    let check = FirstRunShortcutCheck.evaluate(
      shortcut, editModeShortcut: nil, systemShortcuts: [], status: status)

    #expect(check == .available(shortcut))
    #expect(
      FirstRunSetupEvaluation.shortcutState(check: check, permissionState: .notNeeded)
        == .completed)
  }

  @Test("PERM-01: 重なりがなくても、ショートカットに要る権限がなければ操作が要る")
  func shortcutNeedsPermission() {
    #expect(
      FirstRunSetupEvaluation.shortcutState(
        check: .available(shortcut), permissionState: .needsAction) == .needsAction)
  }

  // MARK: 整形の実行先の手順

  @Test("AI-03: 整形の実行先は、選ぶと完了、あとでなら飛ばした扱い、まだなら操作が要る")
  func refinementState() {
    #expect(FirstRunSetupEvaluation.refinementState(decision: .chosen) == .completed)
    #expect(FirstRunSetupEvaluation.refinementState(decision: .deferred) == .deferred)
    #expect(FirstRunSetupEvaluation.refinementState(decision: nil) == .needsAction)
  }
}
