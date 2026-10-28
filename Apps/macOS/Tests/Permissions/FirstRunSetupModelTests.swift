import Testing
import UtterCore
import UtterPersistence
import UtterSpeech

/// 権限の状態の代わり。要求すると許可されたことにし、要求の回数を数える
@MainActor
final class StubPermissionAccess: PermissionAccess {
  var snapshot: PermissionSnapshot
  private(set) var requested: [AppPermission] = []

  init(_ snapshot: PermissionSnapshot = PermissionSnapshot()) {
    self.snapshot = snapshot
  }

  func currentSnapshot() -> PermissionSnapshot {
    snapshot
  }

  func request(_ permission: AppPermission) async {
    requested.append(permission)
    snapshot.statuses[permission] = .granted
  }

  func openSystemSettings(for permission: AppPermission) {}
}

@MainActor
struct FirstRunSetupModelTests {
  private let suite: TestDefaults
  private let shortcut = KeyCombination(key: .space, modifiers: [.option, .command])

  init() throws {
    suite = try TestDefaults()
  }

  private var store: AppSettingsStore { AppSettingsStore(defaults: suite.defaults) }

  private func makeModel(
    access: StubPermissionAccess = StubPermissionAccess(),
    engine: STTEngineKind? = nil, assets: StubSpeechModelAssets? = nil,
    systemShortcuts: [ShortcutBinding] = []
  ) -> FirstRunSetupModel {
    let permissionDefaults = PermissionDefaults(defaults: suite.defaults)
    return FirstRunSetupModel(
      permissions: PermissionOnboardingModel(
        configuration: .phase0Pending, access: access, defaults: permissionDefaults),
      speechModel: assets.map { SpeechModelSettingsModel(assets: $0) }, sttEngine: engine,
      store: store, defaults: FirstRunSetupDefaults(defaults: suite.defaults),
      loadSystemShortcuts: { systemShortcuts }, shortcutStatus: { .unassigned })
  }

  /// マイクとアクセシビリティを許可済みの権限
  private func grantedAccess() -> StubPermissionAccess {
    StubPermissionAccess(PermissionSnapshot([.microphone: .granted, .accessibility: .granted]))
  }

  /// 整形の実行先の手順まで進める
  private func advanceToRefinement(_ model: FirstRunSetupModel) {
    model.advance()
    model.advance()
    model.advance()
    model.assignShortcut(shortcut)
    model.advance()
  }

  // MARK: 進み具合と再開

  @Test("PERM-01: 最初はマイクの手順から始め、許可するまで次へ進まない")
  func startsAtMicrophone() async {
    let access = StubPermissionAccess()
    let model = makeModel(access: access)
    await model.refresh()

    #expect(model.progress == FirstRunSetupProgress(current: .microphone, isFinished: false))
    #expect(model.state(of: .microphone) == .needsAction)
    #expect(!model.canAdvance)
    model.advance()
    #expect(model.progress.current == .microphone)
    #expect(access.requested.isEmpty)
  }

  @Test("PERM-01: 画面のボタンで許可すると、次の手順へ進める")
  func advancesAfterGranting() async throws {
    let access = StubPermissionAccess()
    let model = makeModel(access: access)
    await model.refresh()

    let step = try #require(model.permissionSteps(for: .microphone).first)
    await model.permissions.perform(step)
    model.advance()

    #expect(access.requested == [.microphone])
    #expect(model.progress.current == .accessibility)
    #expect(model.state(of: .microphone) == .completed)
  }

  @Test("PERM-03: 途中で閉じても、次の起動で続きの手順から始める")
  func resumesFromSavedStep() async {
    let model = makeModel(access: grantedAccess())
    await model.refresh()
    model.advance()
    model.advance()

    let resumed = makeModel(access: grantedAccess())

    #expect(resumed.progress == FirstRunSetupProgress(current: .speechModel, isFinished: false))
  }

  @Test("PERM-03: 戻ると前の手順になり、それも保存する")
  func goBackIsSaved() async {
    let model = makeModel(access: grantedAccess())
    await model.refresh()
    model.advance()
    model.goBack()

    #expect(model.progress.current == .microphone)
    #expect(makeModel().progress.current == .microphone)
  }

  // MARK: 認識モデル

  @Test("PERM-03: エンジンが未設定なら、取得のボタンを出さず、未設定として次へ進める")
  func speechModelWithoutEngine() async {
    let model = makeModel(access: grantedAccess())
    await model.refresh()
    model.advance()
    model.advance()

    #expect(model.progress.current == .speechModel)
    #expect(model.speechModel == nil)
    #expect(model.speechModelDescription == nil)
    #expect(model.state(of: .speechModel) == .unavailable(.speechEngineNotConfigured))
    #expect(model.canAdvance)
  }

  @Test("PERM-03: 状態を確かめるだけでは取得せず、「取得を開始」で一度だけ取得する")
  func installsOnlyOnUserAction() async {
    let assets = StubSpeechModelAssets(availability: .notInstalled)
    let model = makeModel(access: grantedAccess(), engine: .speechAnalyzer, assets: assets)
    await model.refresh()
    await model.refresh()

    #expect(assets.installCount == 0)
    #expect(model.speechModelDescription != nil)
    #expect(model.state(of: .speechModel) == .needsAction)

    await model.installSpeechModel()
    await model.installSpeechModel()

    #expect(assets.installCount == 1)
    #expect(model.state(of: .speechModel) == .completed)
  }

  @Test("PERM-03: 取得に失敗したら、手順は操作が要るままにする")
  func installFailureKeepsStepOpen() async {
    let assets = StubSpeechModelAssets(
      availability: .notInstalled, installError: StubSpeechModelAssets.InstallFailure())
    let model = makeModel(access: grantedAccess(), engine: .speechAnalyzer, assets: assets)
    await model.refresh()

    await model.installSpeechModel()

    #expect(model.speechModel?.installFailed == true)
    #expect(model.state(of: .speechModel) == .needsAction)
  }

  // MARK: ショートカット

  @Test("REC-01: 記録した組み合わせは録音ショートカットだけを保存し、ほかの項目は保存先の最新の値のまま")
  func assignsShortcutOnly() throws {
    let model = makeModel()
    // ほかの画面で変えた項目
    var settings = store.load()
    settings.refinementMode = .structured
    try store.save(settings)

    model.assignShortcut(shortcut)

    let saved = store.load()
    #expect(saved.recordingShortcut == shortcut)
    #expect(saved.refinementMode == .structured)
    #expect(model.recordingShortcut == shortcut)
    #expect(model.shortcutCheck == .available(shortcut))
    #expect(model.state(of: .shortcut) == .completed)
  }

  @Test("REC-02: システムのショートカットと重なる組み合わせは保存せず、重なりを示す")
  func rejectsConflictingShortcut() {
    let model = makeModel(
      systemShortcuts: [ShortcutBinding(id: "system.index.0", combination: shortcut)])

    model.assignShortcut(shortcut)

    #expect(store.load().recordingShortcut == nil)
    #expect(model.rejectedShortcut == .rejected(shortcut, .conflictsWithSystemShortcut))
    #expect(model.state(of: .shortcut) == .needsAction)

    model.beginRecordingShortcut()
    #expect(model.rejectedShortcut == nil)
  }

  @Test("AC-14: Edit Mode のショートカットと同じ組み合わせは保存しない")
  func rejectsEditModeShortcut() throws {
    var settings = store.load()
    settings.editModeShortcut = shortcut
    try store.save(settings)
    let model = makeModel()

    model.assignShortcut(shortcut)

    #expect(store.load().recordingShortcut == nil)
    #expect(model.rejectedShortcut == .sameAsEditMode(shortcut))
  }

  // MARK: 整形の実行先

  @Test("AC-06: 「あとで」は設定を変えず（Local Basic のまま）、セットアップを終える")
  func defersRefinement() async {
    let model = makeModel(access: grantedAccess())
    await model.refresh()
    advanceToRefinement(model)
    #expect(model.progress.current == .refinement)
    // 整形の実行先の手順は「次へ」では終えない
    #expect(!model.canAdvance)

    model.deferRefinement()

    #expect(model.progress == FirstRunSetupProgress(current: .refinement, isFinished: true))
    #expect(model.state(of: .refinement) == .deferred)
    #expect(store.load().refinementEngine == .localBasic)
    let reopened = FirstRunSetupDefaults(defaults: suite.defaults)
    #expect(reopened.progress.isFinished)
    #expect(reopened.refinementDecision == .deferred)
  }

  @Test("AI-03: 選んだ実行先を保存してセットアップを終える。同意は変えない")
  func choosesRefinement() async {
    let model = makeModel(access: grantedAccess())
    await model.refresh()
    advanceToRefinement(model)
    let consentsBefore = store.load().consentState

    model.chooseRefinement(.chatGPTSignIn)

    let saved = store.load()
    #expect(saved.refinementEngine == .cloudAI)
    #expect(saved.cloudRefinementProvider == .chatGPTSignIn)
    #expect(saved.consentState == consentsBefore)
    #expect(model.refinementChoice == .chatGPTSignIn)
    #expect(model.progress.isFinished)
    #expect(model.state(of: .refinement) == .completed)
  }

  @Test("AI-03: 準備中の選択肢（OpenAI API キー方式）は選んでも保存せず、終えない")
  func ignoresUnselectableRefinement() async {
    let model = makeModel(access: grantedAccess())
    await model.refresh()
    advanceToRefinement(model)

    model.chooseRefinement(.openAIAPIKey)

    #expect(store.load().refinementEngine == .localBasic)
    #expect(!model.progress.isFinished)
    #expect(model.state(of: .refinement) == .needsAction)
  }

  @Test("PERM-03: 終えた後に見直すと、最初の手順から始める")
  func restartsAfterFinishing() async {
    let model = makeModel(access: grantedAccess())
    await model.refresh()
    advanceToRefinement(model)
    model.deferRefinement()

    model.restart()

    #expect(model.progress == FirstRunSetupProgress(current: .microphone, isFinished: false))
    #expect(!FirstRunSetupDefaults(defaults: suite.defaults).progress.isFinished)
  }
}
