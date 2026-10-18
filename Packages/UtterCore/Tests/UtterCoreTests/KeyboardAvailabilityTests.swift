import Testing

@testable import UtterCore

struct KeyboardAvailabilityTests {
  private static let readyHost = HostAppStatus(
    deniedPermissions: [], speechModel: .ready, network: .online, usesCloudRefinement: true)

  private static func environment(
    hasFullAccess: Bool = true,
    canAccessSharedContainer: Bool = true,
    inputField: KeyboardInputField = .regular,
    hostApp: HostAppStatus? = readyHost
  ) -> KeyboardEnvironment {
    KeyboardEnvironment(
      hasFullAccess: hasFullAccess, canAccessSharedContainer: canAccessSharedContainer,
      inputField: inputField, hostApp: hostApp)
  }

  @Test("iAC-07: 問題がなければ全操作を提示し、案内を出さない")
  func allAvailable() {
    let availability = KeyboardAvailability(Self.environment())

    #expect(availability.actions == [.typing, .sharedResult, .openHostApp])
    #expect(availability.notices.isEmpty)
  }

  /// 入力欄の属性の全組み合わせ（3 × 3 = 9 通り）と、期待する制限の理由
  static let fieldCases: [(KeyboardInputField, Set<KeyboardFieldRestriction>)] =
    SensitiveSignal.allCases.flatMap { secure in
      SensitiveSignal.allCases.map { phone in
        var expected: Set<KeyboardFieldRestriction> = []
        if secure == .on { expected.insert(.secureTextEntry) }
        if phone == .on { expected.insert(.phoneNumber) }
        if secure == .unknown || phone == .unknown { expected.insert(.undetermined) }
        return (KeyboardInputField(secureTextEntry: secure, phoneNumber: phone), expected)
      }
    }

  @Test(
    "iOS-09, iAC-06: セキュア入力欄・電話番号欄・判定できない欄では文字入力だけを残し、標準キーボードへの切り替えを案内する",
    arguments: fieldCases)
  func restrictedFields(_ field: KeyboardInputField, _ expected: Set<KeyboardFieldRestriction>) {
    let availability = KeyboardAvailability(Self.environment(inputField: field))

    if expected.isEmpty {
      #expect(availability.actions == [.typing, .sharedResult, .openHostApp])
      #expect(availability.notices.isEmpty)
    } else {
      #expect(availability.actions == [.typing])
      #expect(availability.notices == [.restrictedInputField(expected)])
      #expect(availability.notices.map(\.remedy) == [.switchToSystemKeyboard])
    }
  }

  @Test("iOS-09, iAC-06: 制限のある入力欄では他の問題があっても共有結果と本体アプリへの移動を提示しない")
  func restrictedFieldOverridesOtherStates() {
    let host = HostAppStatus(
      deniedPermissions: [.microphone], speechModel: .notDownloaded, network: .offline,
      usesCloudRefinement: true)
    let availability = KeyboardAvailability(
      Self.environment(
        hasFullAccess: false, canAccessSharedContainer: false,
        inputField: KeyboardInputField(secureTextEntry: .on, phoneNumber: .off), hostApp: host))

    #expect(availability.actions == [.typing])
    #expect(availability.notices == [.restrictedInputField([.secureTextEntry])])
  }

  @Test("iAC-07: フルアクセスが無効で共有結果を読めなければ、フルアクセスの許可を案内する")
  func fullAccessDisabled() {
    let availability = KeyboardAvailability(
      Self.environment(hasFullAccess: false, canAccessSharedContainer: false))

    #expect(availability.actions == [.typing, .openHostApp])
    #expect(availability.notices == [.fullAccessRequired])
    #expect(availability.notices.map(\.remedy) == [.enableFullAccess])
  }

  @Test("iAC-07: フルアクセスが無効でも共有結果を読めれば、共有結果を提示する")
  func fullAccessDisabledButReadable() {
    let availability = KeyboardAvailability(
      Self.environment(hasFullAccess: false, canAccessSharedContainer: true))

    #expect(availability.actions == [.typing, .sharedResult, .openHostApp])
    #expect(availability.notices.isEmpty)
  }

  @Test("iAC-07: フルアクセスがあっても共有結果を読めなければ、署名の不備として入れ直しを案内する")
  func signingProblem() {
    let availability = KeyboardAvailability(
      Self.environment(hasFullAccess: true, canAccessSharedContainer: false))

    #expect(availability.actions == [.typing, .openHostApp])
    #expect(availability.notices == [.sharedContainerUnavailable])
    #expect(availability.notices.map(\.remedy) == [.reinstallWithValidSigning])
  }

  @Test("iAC-07: 拒否された権限ごとに、設定での許可を案内する")
  func permissionDenied() {
    let host = HostAppStatus(
      deniedPermissions: [.speechRecognition, .microphone], speechModel: .ready, network: .online,
      usesCloudRefinement: false)
    let availability = KeyboardAvailability(Self.environment(hostApp: host))

    #expect(availability.actions == [.typing, .sharedResult, .openHostApp])
    #expect(
      availability.notices == [
        .permissionDenied(.microphone), .permissionDenied(.speechRecognition),
      ]
    )
    #expect(
      availability.notices.map(\.remedy) == [
        .allowPermission(.microphone), .allowPermission(.speechRecognition),
      ])
  }

  @Test(
    "iAC-07: モデル未取得とオフラインの組み合わせに応じて案内する",
    arguments: [
      (SpeechModelAvailability.ready, NetworkReachability.online, false, [KeyboardNotice]()),
      (.ready, .offline, false, []),
      (.ready, .online, true, []),
      (.ready, .offline, true, [.cloudRefinementOffline]),
      (.notDownloaded, .online, false, [.speechModelNotDownloaded]),
      (.notDownloaded, .online, true, [.speechModelNotDownloaded]),
      (.notDownloaded, .offline, false, [.speechModelNotDownloadedOffline]),
      (
        .notDownloaded, .offline, true, [.speechModelNotDownloadedOffline, .cloudRefinementOffline]
      ),
    ])
  func modelAndNetwork(
    _ model: SpeechModelAvailability, _ network: NetworkReachability, _ cloud: Bool,
    _ expected: [KeyboardNotice]
  ) {
    let host = HostAppStatus(
      deniedPermissions: [], speechModel: model, network: network, usesCloudRefinement: cloud)
    let availability = KeyboardAvailability(Self.environment(hostApp: host))

    #expect(availability.actions == [.typing, .sharedResult, .openHostApp])
    #expect(availability.notices == expected)
  }

  @Test("iAC-07: 対処はモデル未取得なら本体アプリでの取得、オフラインならネットワーク接続")
  func modelAndNetworkRemedies() {
    #expect(KeyboardNotice.speechModelNotDownloaded.remedy == .downloadSpeechModel)
    #expect(KeyboardNotice.speechModelNotDownloadedOffline.remedy == .connectToNetwork)
    #expect(KeyboardNotice.cloudRefinementOffline.remedy == .connectToNetwork)
  }

  @Test("iAC-07: 複数の問題は共有結果・権限・モデル・整形の順に案内する")
  func noticeOrder() {
    let host = HostAppStatus(
      deniedPermissions: [.microphone], speechModel: .notDownloaded, network: .offline,
      usesCloudRefinement: true)
    let availability = KeyboardAvailability(
      Self.environment(hasFullAccess: false, canAccessSharedContainer: false, hostApp: host))

    #expect(availability.actions == [.typing, .openHostApp])
    #expect(
      availability.notices == [
        .fullAccessRequired, .permissionDenied(.microphone), .speechModelNotDownloadedOffline,
        .cloudRefinementOffline,
      ])
  }

  @Test("iAC-07: 本体アプリの状態が分からなければ、本体アプリの案内を出さない")
  func unknownHostApp() {
    let availability = KeyboardAvailability(Self.environment(hostApp: nil))

    #expect(availability.actions == [.typing, .sharedResult, .openHostApp])
    #expect(availability.notices.isEmpty)
  }
}
