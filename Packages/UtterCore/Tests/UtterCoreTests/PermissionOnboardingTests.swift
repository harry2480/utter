import Testing

@testable import UtterCore

struct PermissionOnboardingTests {
  /// Phase 0 の結果を仮に置いた要件。テストごとに必要な部分だけ変える
  private static func requirements(
    transcription: Set<AppPermission> = [.speechRecognition],
    insertionRoutes: [InsertionRoute: Set<AppPermission>] = [
      .accessibility: [.accessibility], .pasteboard: [.accessibility],
    ],
    modifierOnlyShortcut: Set<AppPermission> = [.inputMonitoring]
  ) -> PermissionRequirements {
    PermissionRequirements(
      transcription: transcription, insertionRoutes: insertionRoutes,
      modifierOnlyShortcut: modifierOnlyShortcut, escapeCancel: [])
  }

  private static let features: Set<AppFeature> = [
    .recording, .insertion(.accessibility), .modifierOnlyShortcut,
  ]

  private static let allGranted = PermissionSnapshot(
    Dictionary(uniqueKeysWithValues: AppPermission.allCases.map { ($0, .granted) }))

  // MARK: PERM-01

  @Test("PERM-01: 有効な機能に要る権限だけを、マイク → 音声認識 → Accessibility → 入力監視の順に案内する")
  func stepsFollowEnabledFeaturesInOrder() {
    let onboarding = PermissionOnboarding(
      features: Self.features, permissions: PermissionSnapshot(),
      requirements: Self.requirements())

    #expect(
      onboarding.steps.map(\.permission)
        == [.microphone, .speechRecognition, .accessibility, .inputMonitoring])
    #expect(
      onboarding.steps.map(\.state)
        == Array(repeating: .needed(.requestFromSystem, wasRevoked: false), count: 4))
    #expect(onboarding.steps[0].features == [.recording])
    #expect(onboarding.steps[2].features == [.insertion(.accessibility)])
    #expect(onboarding.currentStep?.permission == .microphone)
    #expect(!onboarding.isComplete)
  }

  @Test("PERM-01: 使わない機能・要件で要らないとされた権限は案内しない")
  func omitsUnusedPermissions() {
    let onboarding = PermissionOnboarding(
      features: [.recording, .insertion(.accessibility)], permissions: PermissionSnapshot(),
      requirements: Self.requirements(transcription: []))

    #expect(onboarding.steps.map(\.permission) == [.microphone, .accessibility])
  }

  @Test("PERM-01: 許可済みの段階は許可済みとして残し、次の段階を案内する")
  func advancesToNextStep() {
    let onboarding = PermissionOnboarding(
      features: Self.features,
      permissions: PermissionSnapshot([.microphone: .granted, .speechRecognition: .granted]),
      requirements: Self.requirements())

    #expect(onboarding.steps.map(\.state).prefix(2) == [.granted, .granted])
    #expect(onboarding.currentStep?.permission == .accessibility)
  }

  @Test("PERM-01: 拒否済みはシステム設定へ、制限されている権限は飛ばして次を案内する")
  func deniedAndRestrictedSteps() {
    let onboarding = PermissionOnboarding(
      features: Self.features,
      permissions: PermissionSnapshot([
        .microphone: .restricted, .speechRecognition: .denied,
      ]),
      requirements: Self.requirements())

    #expect(onboarding.steps[0].state == .needed(.notChangeableByUser, wasRevoked: false))
    #expect(onboarding.steps[1].state == .needed(.openSystemSettings, wasRevoked: false))
    #expect(onboarding.currentStep?.permission == .speechRecognition)
  }

  @Test("PERM-01: 制限された権限だけが残ると、案内する段階はないが完了ではない")
  func onlyRestrictedRemains() {
    var permissions = Self.allGranted
    permissions.statuses[.inputMonitoring] = .restricted
    let onboarding = PermissionOnboarding(
      features: Self.features, permissions: permissions, requirements: Self.requirements())

    #expect(onboarding.currentStep == nil)
    #expect(!onboarding.isComplete)
  }

  @Test("PERM-01: すべて許可されれば完了")
  func completes() {
    let onboarding = PermissionOnboarding(
      features: Self.features, permissions: Self.allGranted, requirements: Self.requirements())

    #expect(onboarding.steps.allSatisfy { $0.state == .granted })
    #expect(onboarding.currentStep == nil)
    #expect(onboarding.isComplete)
    #expect(onboarding.availability.availableFeatures == Self.features)
  }

  @Test("PERM-01: 要る権限が未定の経路は段階に出さず、未定の機能として分ける")
  func undecidedRoutesAreSeparated() {
    let onboarding = PermissionOnboarding(
      features: [.recording, .insertion(.pasteboard), .insertion(.keyEvents)],
      permissions: Self.allGranted,
      requirements: Self.requirements(transcription: [], insertionRoutes: [:]))

    #expect(onboarding.steps.map(\.permission) == [.microphone])
    #expect(onboarding.undecidedFeatures == [.insertion(.pasteboard), .insertion(.keyEvents)])
    #expect(onboarding.availability.permittedRoutes.isEmpty)
    #expect(onboarding.isComplete)
  }

  // MARK: PERM-02

  @Test("PERM-02: 取り消された権限は取り消しとして示し、システム設定での許可し直しを案内する")
  func revokedStep() {
    var permissions = Self.allGranted
    permissions.statuses[.accessibility] = .denied
    permissions.statuses[.inputMonitoring] = .denied
    let onboarding = PermissionOnboarding(
      features: Self.features, permissions: permissions, requirements: Self.requirements(),
      previous: PermissionHistory(grantedPermissions: [.microphone, .accessibility])
        .previousSnapshot)

    #expect(onboarding.steps[2].state == .needed(.openSystemSettings, wasRevoked: true))
    #expect(onboarding.steps[3].state == .needed(.openSystemSettings, wasRevoked: false))
    #expect(onboarding.currentStep?.permission == .accessibility)
    #expect(onboarding.availability.permittedRoutes.isEmpty)
    #expect(onboarding.availability.canStartRecording)
  }

  @Test("PERM-02: 一度許可された権限を覚え、取り消し後の観測を挟んでも取り消しを示し続ける")
  func historyKeepsRevocation() {
    var history = PermissionHistory()
    history.record(Self.allGranted)
    var revoked = Self.allGranted
    revoked.statuses[.microphone] = .denied

    for _ in 0..<2 {
      let onboarding = PermissionOnboarding(
        features: [.recording], permissions: revoked,
        requirements: Self.requirements(transcription: []),
        previous: history.previousSnapshot)
      #expect(
        onboarding.steps == [
          PermissionOnboardingStep(
            permission: .microphone, features: [.recording],
            state: .needed(.openSystemSettings, wasRevoked: true))
        ])
      #expect(!onboarding.availability.canStartRecording)
      history.record(revoked)
    }

    let regranted = PermissionOnboarding(
      features: [.recording], permissions: Self.allGranted,
      requirements: Self.requirements(transcription: []), previous: history.previousSnapshot)
    #expect(regranted.isComplete)
  }

  @Test("PERM-02: 許可を観測したことのない拒否は取り消しとして示さない")
  func firstDenialIsNotRevocation() {
    var history = PermissionHistory()
    history.record(PermissionSnapshot([.microphone: .denied]))

    #expect(history.grantedPermissions.isEmpty)
    let onboarding = PermissionOnboarding(
      features: [.recording], permissions: PermissionSnapshot([.microphone: .denied]),
      requirements: Self.requirements(transcription: []), previous: history.previousSnapshot)
    #expect(onboarding.steps.first?.state == .needed(.openSystemSettings, wasRevoked: false))
  }
}
