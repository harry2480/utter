import Testing

@testable import UtterCore

struct FeatureAvailabilityTests {
  /// Phase 0 の結果を仮に置いた要件。テストごとに必要な部分だけ変える
  private static func requirements(
    transcription: Set<AppPermission> = [.speechRecognition],
    insertionRoutes: [InsertionRoute: Set<AppPermission>] = [
      .accessibility: [.accessibility], .pasteboard: [.accessibility], .keyEvents: [.accessibility],
    ],
    modifierOnlyShortcut: Set<AppPermission> = [.inputMonitoring],
    escapeCancel: Set<AppPermission> = []
  ) -> PermissionRequirements {
    PermissionRequirements(
      transcription: transcription, insertionRoutes: insertionRoutes,
      modifierOnlyShortcut: modifierOnlyShortcut, escapeCancel: escapeCancel)
  }

  private static let basicFeatures: Set<AppFeature> = [
    .recording, .insertion(.accessibility), .escapeCancel,
  ]

  private static let allGranted = PermissionSnapshot(
    Dictionary(uniqueKeysWithValues: AppPermission.allCases.map { ($0, .granted) }))

  // MARK: PERM-01

  @Test("PERM-01: 使わない機能の権限は要求に出さない")
  func omitsUnusedPermissions() {
    let requirements = Self.requirements()

    #expect(
      requirements.requiredPermissions(for: Self.basicFeatures)
        == [.microphone, .speechRecognition, .accessibility])
    #expect(
      requirements.requiredPermissions(for: [.recording]) == [.microphone, .speechRecognition])
    #expect(
      Self.requirements(transcription: []).requiredPermissions(for: [.recording]) == [.microphone])
  }

  @Test("PERM-01: 音声認識・入力監視は要件で要るとされた場合だけ要求する")
  func optionalPermissionsFollowRequirements() {
    let requirements = Self.requirements(transcription: [], modifierOnlyShortcut: [])
    let features = Self.basicFeatures.union([.modifierOnlyShortcut])

    #expect(requirements.requiredPermissions(for: features) == [.microphone, .accessibility])
  }

  @Test("PERM-01: 要求はマイク → 音声認識 → Accessibility → 入力監視の順")
  func requestOrder() {
    let features = Self.basicFeatures.union([.modifierOnlyShortcut])

    #expect(
      Self.requirements().requiredPermissions(for: features)
        == [.microphone, .speechRecognition, .accessibility, .inputMonitoring])
  }

  @Test("PERM-01: 許可済みの権限は要求せず、要求には用途となる機能と操作を添える")
  func requestsWithPurpose() {
    let features: Set<AppFeature> = [
      .recording, .insertion(.accessibility), .insertion(.pasteboard), .modifierOnlyShortcut,
    ]
    let current = PermissionSnapshot([
      .microphone: .granted, .speechRecognition: .granted, .accessibility: .denied,
    ])

    #expect(
      Self.requirements().requests(for: features, current: current) == [
        PermissionRequest(
          permission: .accessibility,
          features: [.insertion(.accessibility), .insertion(.pasteboard)],
          action: .openSystemSettings),
        PermissionRequest(
          permission: .inputMonitoring, features: [.modifierOnlyShortcut],
          action: .requestFromSystem),
      ])
  }

  @Test("PERM-01: 要る権限が分からない経路の権限は要求しない")
  func unknownRouteRequestsNothing() {
    let requirements = Self.requirements(insertionRoutes: [:])

    #expect(requirements.permissions(for: .insertion(.pasteboard)) == nil)
    #expect(requirements.requiredPermissions(for: [.insertion(.pasteboard)]).isEmpty)
  }

  // MARK: PERM-02

  @Test("PERM-02: 権限がそろっていればすべての機能を使える")
  func allAvailable() {
    let features = Self.basicFeatures.union([.modifierOnlyShortcut, .insertion(.pasteboard)])
    let availability = FeatureAvailability(
      features: features, permissions: Self.allGranted, requirements: Self.requirements())

    #expect(availability.availableFeatures == features)
    #expect(availability.unavailableFeatures.isEmpty)
    #expect(availability.notices.isEmpty)
    #expect(availability.canStartRecording)
    #expect(availability.permittedRoutes == [.accessibility, .pasteboard])
  }

  @Test("PERM-02: Accessibility を取り消すと、それが要る経路だけが外れる")
  func accessibilityRevocationDisablesOnlyDependentRoutes() {
    let requirements = Self.requirements(insertionRoutes: [
      .accessibility: [.accessibility], .pasteboard: [], .keyEvents: [.accessibility],
    ])
    let features = Self.basicFeatures.union([.insertion(.pasteboard), .insertion(.keyEvents)])
    var current = Self.allGranted
    current.statuses[.accessibility] = .denied

    let availability = FeatureAvailability(
      features: features, permissions: current, requirements: requirements,
      previous: Self.allGranted)

    #expect(availability.permittedRoutes == [.pasteboard])
    #expect(availability.canStartRecording)
    #expect(availability.availableFeatures.contains(.escapeCancel))
    #expect(
      availability.unavailableFeatures == [
        .insertion(.accessibility): .missingPermissions([.accessibility]),
        .insertion(.keyEvents): .missingPermissions([.accessibility]),
      ])
    #expect(
      availability.notices == [
        PermissionNotice(
          permission: .accessibility,
          disabledFeatures: [.insertion(.accessibility), .insertion(.keyEvents)],
          wasRevoked: true, action: .openSystemSettings)
      ])
  }

  @Test("PERM-02: 外れた経路は InsertionPolicy の計画からも外れ、全部外れたらプレビューへ退避する")
  func connectsToInsertionPolicy() {
    var current = Self.allGranted
    current.statuses[.accessibility] = .denied
    let features = Self.basicFeatures.union([.insertion(.pasteboard), .insertion(.keyEvents)])
    let availability = FeatureAvailability(
      features: features, permissions: current, requirements: Self.requirements())
    let target = InsertionTargetID(rawValue: "window-1/field-1")

    let plan = InsertionPolicy().plan(
      app: nil, verification: .compare(recorded: target),
      permittedRoutes: availability.permittedRoutes)

    #expect(plan.routes.isEmpty)
    #expect(
      plan.nextStep(after: [], currentTarget: target) == .showPreview(.noAvailableRoute))
  }

  @Test(
    "REC-04: マイクが許可されていない間は録音を始めない",
    arguments: [PermissionStatus.denied, .notDetermined])
  func microphoneDeniedBlocksRecording(_ status: PermissionStatus) {
    var current = Self.allGranted
    current.statuses[.microphone] = status

    let availability = FeatureAvailability(
      features: Self.basicFeatures, permissions: current, requirements: Self.requirements())

    #expect(!availability.canStartRecording)
    #expect(availability.unavailableFeatures == [.recording: .missingPermissions([.microphone])])
    #expect(availability.permittedRoutes == [.accessibility])
    #expect(
      availability.notices.map(\.action)
        == [status == .denied ? .openSystemSettings : .requestFromSystem])
  }

  @Test("REC-04: 音声認識の権限が要る STT で拒否されていれば録音を始めない")
  func speechRecognitionDeniedBlocksRecording() {
    var current = Self.allGranted
    current.statuses[.speechRecognition] = .denied

    let availability = FeatureAvailability(
      features: Self.basicFeatures, permissions: current, requirements: Self.requirements())

    #expect(!availability.canStartRecording)
    #expect(
      availability.unavailableFeatures == [.recording: .missingPermissions([.speechRecognition])])
    #expect(availability.permittedRoutes == [.accessibility])
  }

  @Test("REC-04: 音声認識の権限が要らない STT では、その権限がなくても録音を始められる")
  func speechRecognitionNotRequired() {
    let availability = FeatureAvailability(
      features: Self.basicFeatures, permissions: PermissionSnapshot([.microphone: .granted]),
      requirements: Self.requirements(transcription: [], escapeCancel: [.inputMonitoring]))

    #expect(availability.canStartRecording)
    #expect(
      Set(availability.unavailableFeatures.keys) == [.escapeCancel, .insertion(.accessibility)])
    #expect(availability.notices.map(\.permission) == [.accessibility, .inputMonitoring])
  }

  @Test("REC-02: 入力監視がなければ修飾キー単独のショートカットだけを無効にし、要求に出す")
  func modifierOnlyShortcutNeedsPermission() {
    let features = Self.basicFeatures.union([.modifierOnlyShortcut])
    var current = Self.allGranted
    current.statuses[.inputMonitoring] = .notDetermined

    let availability = FeatureAvailability(
      features: features, permissions: current, requirements: Self.requirements())

    #expect(availability.availableFeatures == Self.basicFeatures)
    #expect(availability.canStartRecording)
    #expect(
      Self.requirements().requests(for: features, current: current) == [
        PermissionRequest(
          permission: .inputMonitoring, features: [.modifierOnlyShortcut],
          action: .requestFromSystem)
      ])
  }

  @Test("PERM-02: 取り消された権限を要する機能を使っていなければ案内しない")
  func revokedButUnused() {
    var current = Self.allGranted
    current.statuses[.inputMonitoring] = .denied

    let availability = FeatureAvailability(
      features: Self.basicFeatures, permissions: current, requirements: Self.requirements(),
      previous: Self.allGranted)

    #expect(availability.availableFeatures == Self.basicFeatures)
    #expect(availability.notices.isEmpty)
  }

  @Test("PERM-02: 要る権限がない機能は、どの権限の状態でも使える")
  func featureWithoutPermissions() {
    let availability = FeatureAvailability(
      features: [.escapeCancel], permissions: PermissionSnapshot(),
      requirements: Self.requirements(escapeCancel: []))

    #expect(availability.availableFeatures == [.escapeCancel])
    #expect(availability.notices.isEmpty)
  }

  @Test("PERM-01: 有効な機能がなければ何も要求せず、何も案内しない")
  func noFeatures() {
    let availability = FeatureAvailability(
      features: [], permissions: PermissionSnapshot(), requirements: Self.requirements())

    #expect(Self.requirements().requests(for: [], current: PermissionSnapshot()).isEmpty)
    #expect(availability.availableFeatures.isEmpty)
    #expect(availability.notices.isEmpty)
    #expect(!availability.canStartRecording)
  }

  @Test("PERM-02: 取り消し後に未確認へ戻った権限は OS のダイアログで要求し直す")
  func revokedToNotDeterminedRequestsAgain() {
    let current = PermissionSnapshot([.microphone: .granted, .speechRecognition: .granted])
    let availability = FeatureAvailability(
      features: Self.basicFeatures, permissions: current, requirements: Self.requirements(),
      previous: Self.allGranted)

    #expect(
      availability.notices == [
        PermissionNotice(
          permission: .accessibility, disabledFeatures: [.insertion(.accessibility)],
          wasRevoked: true, action: .requestFromSystem)
      ])
    #expect(
      Self.requirements().requests(for: Self.basicFeatures, current: current).map(\.action)
        == [.requestFromSystem])
  }

  @Test("PERM-02: 制限されている権限は利用者に変えられないと案内する")
  func restrictedPermission() {
    let current = PermissionSnapshot([.microphone: .restricted])
    let availability = FeatureAvailability(
      features: [.recording], permissions: current,
      requirements: Self.requirements(transcription: []))

    #expect(!availability.canStartRecording)
    #expect(availability.notices.map(\.action) == [.notChangeableByUser])
    #expect(
      Self.requirements(transcription: []).requests(for: [.recording], current: current)
        .map(\.action) == [.notChangeableByUser])
  }

  @Test("PERM-02: 要る権限が分からない経路は使わず、権限の案内も出さない")
  func unknownRouteIsUnavailable() {
    let availability = FeatureAvailability(
      features: [.insertion(.accessibility), .insertion(.pasteboard)],
      permissions: Self.allGranted,
      requirements: Self.requirements(insertionRoutes: [.accessibility: [.accessibility]]))

    #expect(availability.permittedRoutes == [.accessibility])
    #expect(availability.unavailableFeatures == [.insertion(.pasteboard): .unknownRequirements])
    #expect(availability.notices.isEmpty)
  }

  @Test("PERM-02: 前回から許可が外れた権限を取り消しとして検出する")
  func detectsRevocation() {
    let previous = PermissionSnapshot([
      .microphone: .granted, .accessibility: .granted, .inputMonitoring: .denied,
    ])
    let current = PermissionSnapshot([
      .microphone: .granted, .accessibility: .notDetermined, .speechRecognition: .denied,
      .inputMonitoring: .denied,
    ])

    #expect(current.revokedPermissions(since: previous) == [.accessibility])
    #expect(previous.revokedPermissions(since: previous).isEmpty)
  }

  @Test("PERM-02: 前回の状態を渡さなければ、拒否中の権限を取り消しとは示さない")
  func noticeWithoutPrevious() {
    let availability = FeatureAvailability(
      features: [.insertion(.accessibility)],
      permissions: PermissionSnapshot([.accessibility: .denied]),
      requirements: Self.requirements())

    #expect(availability.notices.map(\.wasRevoked) == [false])
  }
}
