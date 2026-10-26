import Foundation
import Testing

@testable import UtterCore

struct KeyboardAvailabilityTests {
  private static let now = Date(timeIntervalSince1970: 1_800_000_000)

  private static func host(
    observedAt: Date = now,
    deniedPermissions: Set<HostAppPermission> = [],
    speechModel: SpeechModelAvailability = .ready,
    usesCloudRefinement: Bool = true
  ) -> HostAppStatus {
    HostAppStatus(
      observedAt: observedAt, deniedPermissions: deniedPermissions, speechModel: speechModel,
      usesCloudRefinement: usesCloudRefinement)
  }

  private static func environment(
    hasFullAccess: Bool = true,
    sharedContainer: SharedContainerState = .available(hostApp: host()),
    inputField: KeyboardInputField = .regular,
    network: NetworkReachability = .online
  ) -> KeyboardEnvironment {
    KeyboardEnvironment(
      hasFullAccess: hasFullAccess, sharedContainer: sharedContainer, inputField: inputField,
      network: network)
  }

  private static func availability(
    _ environment: KeyboardEnvironment, at now: Date = now
  ) -> KeyboardAvailability {
    KeyboardAvailability(environment, at: now)
  }

  @Test("iAC-07: 問題がなければ全操作を提示し、案内を出さない")
  func allAvailable() {
    let availability = Self.availability(Self.environment())

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
    let availability = Self.availability(Self.environment(inputField: field))

    if expected.isEmpty {
      #expect(availability.actions == [.typing, .sharedResult, .openHostApp])
      #expect(availability.notices.isEmpty)
    } else {
      #expect(availability.actions == [.typing])
      #expect(availability.notices == [.restrictedInputField(expected)])
      #expect(availability.notices.map(\.remedies) == [[.switchToSystemKeyboard]])
    }
  }

  @Test("iOS-09, iAC-06: 制限のある入力欄では他の問題があっても共有結果と本体アプリへの移動を提示しない")
  func restrictedFieldOverridesOtherStates() {
    let host = Self.host(deniedPermissions: [.microphone], speechModel: .notDownloaded)
    let availability = Self.availability(
      Self.environment(
        hasFullAccess: false, sharedContainer: .available(hostApp: host),
        inputField: KeyboardInputField(secureTextEntry: .on, phoneNumber: .off), network: .offline
      ))

    #expect(availability.actions == [.typing])
    #expect(availability.notices == [.restrictedInputField([.secureTextEntry])])
  }

  @Test("iAC-07: フルアクセスが無効で共有結果を読めなければ、フルアクセスの許可を案内する")
  func fullAccessDisabled() {
    let availability = Self.availability(
      Self.environment(hasFullAccess: false, sharedContainer: .unavailable))

    #expect(availability.actions == [.typing, .openHostApp])
    #expect(availability.notices == [.fullAccessRequired])
    #expect(availability.notices.map(\.remedies) == [[.enableFullAccess]])
  }

  @Test("iAC-07: フルアクセスが無効でも共有結果を読めれば、共有結果を提示する")
  func fullAccessDisabledButReadable() {
    let availability = Self.availability(Self.environment(hasFullAccess: false))

    #expect(availability.actions == [.typing, .sharedResult, .openHostApp])
    #expect(availability.notices.isEmpty)
  }

  @Test("iAC-07: フルアクセスがあっても共有結果を読めなければ、署名の不備として入れ直しを案内する")
  func signingProblem() {
    let availability = Self.availability(
      Self.environment(hasFullAccess: true, sharedContainer: .unavailable))

    #expect(availability.actions == [.typing, .openHostApp])
    #expect(availability.notices == [.sharedContainerUnavailable])
    #expect(availability.notices.map(\.remedies) == [[.reinstallWithValidSigning]])
  }

  @Test(
    "iAC-07: App Group を設定していないビルドでは共有結果を提示せず、フルアクセス・署名ではなく共有が未設定と案内する",
    arguments: [true, false])
  func sharingNotConfigured(_ hasFullAccess: Bool) {
    let availability = Self.availability(
      Self.environment(
        hasFullAccess: hasFullAccess, sharedContainer: .notConfigured, network: .offline))

    #expect(availability.actions == [.typing, .openHostApp])
    #expect(availability.notices == [.sharingNotConfigured])
    #expect(availability.notices.map(\.remedies) == [[.rebuildWithAppGroup]])
  }

  @Test("iOS-09, iAC-06: App Group を設定していなくても、制限のある入力欄の案内を優先する")
  func restrictedFieldOverridesNotConfigured() {
    let availability = Self.availability(
      Self.environment(
        sharedContainer: .notConfigured,
        inputField: KeyboardInputField(secureTextEntry: .off, phoneNumber: .on)))

    #expect(availability.actions == [.typing])
    #expect(availability.notices == [.restrictedInputField([.phoneNumber])])
  }

  @Test("iOS-09, iAC-06: 入力欄の制限の理由は、共有コンテナを読む前の確認と案内で同じになる", arguments: fieldCases)
  func fieldRestrictions(_ field: KeyboardInputField, _ expected: Set<KeyboardFieldRestriction>) {
    #expect(field.restrictions == expected)
  }

  @Test("iAC-07: 共有結果を読めなければ、オフラインでも本体アプリの案内を出さない")
  func unavailableContainerShowsOnlyContainerNotice() {
    let availability = Self.availability(
      Self.environment(sharedContainer: .unavailable, network: .offline))

    #expect(availability.notices == [.sharedContainerUnavailable])
  }

  @Test("iAC-07: 拒否された権限ごとに、設定での許可を案内する")
  func permissionDenied() {
    let host = Self.host(
      deniedPermissions: [.speechRecognition, .microphone], usesCloudRefinement: false)
    let availability = Self.availability(
      Self.environment(sharedContainer: .available(hostApp: host)))

    #expect(availability.actions == [.typing, .sharedResult, .openHostApp])
    #expect(
      availability.notices == [
        .permissionDenied(.microphone), .permissionDenied(.speechRecognition),
      ]
    )
    #expect(
      availability.notices.map(\.remedies) == [
        [.allowPermission(.microphone)], [.allowPermission(.speechRecognition)],
      ])
  }

  @Test(
    "iAC-07: モデル未取得と拡張が観測したネットワークの組み合わせに応じて案内する",
    arguments: [
      (SpeechModelAvailability.ready, NetworkReachability.online, false, [KeyboardNotice]()),
      (.ready, .offline, false, []),
      (.ready, .online, true, []),
      (.ready, .offline, true, [.cloudRefinementOffline]),
      (.ready, .unknown, true, []),
      (.notApplicable, .online, false, []),
      (.notApplicable, .offline, true, [.cloudRefinementOffline]),
      (.notDownloaded, .online, false, [.speechModelNotDownloaded]),
      (.notDownloaded, .online, true, [.speechModelNotDownloaded]),
      (.notDownloaded, .unknown, true, [.speechModelNotDownloaded]),
      (.notDownloaded, .offline, false, [.speechModelNotDownloadedOffline]),
      (
        .notDownloaded, .offline, true, [.speechModelNotDownloadedOffline, .cloudRefinementOffline]
      ),
    ])
  func modelAndNetwork(
    _ model: SpeechModelAvailability, _ network: NetworkReachability, _ cloud: Bool,
    _ expected: [KeyboardNotice]
  ) {
    let host = Self.host(speechModel: model, usesCloudRefinement: cloud)
    let availability = Self.availability(
      Self.environment(sharedContainer: .available(hostApp: host), network: network))

    #expect(availability.actions == [.typing, .sharedResult, .openHostApp])
    #expect(availability.notices == expected)
  }

  @Test("iAC-07: モデル未取得なら本体アプリでの取得、オフラインならネットワークへの接続の後に取得を案内する")
  func modelAndNetworkRemedies() {
    #expect(KeyboardNotice.speechModelNotDownloaded.remedies == [.downloadSpeechModel])
    #expect(
      KeyboardNotice.speechModelNotDownloadedOffline.remedies == [
        .connectToNetwork, .downloadSpeechModel,
      ])
    #expect(KeyboardNotice.cloudRefinementOffline.remedies == [.connectToNetwork])
  }

  @Test("iAC-07: 複数の問題は権限・モデル・整形の順に案内する")
  func noticeOrder() {
    let host = Self.host(deniedPermissions: [.microphone], speechModel: .notDownloaded)
    let availability = Self.availability(
      Self.environment(
        hasFullAccess: false, sharedContainer: .available(hostApp: host), network: .offline))

    #expect(availability.actions == [.typing, .sharedResult, .openHostApp])
    #expect(
      availability.notices == [
        .permissionDenied(.microphone), .speechModelNotDownloadedOffline, .cloudRefinementOffline,
      ])
  }

  @Test("iAC-07: 本体アプリの状態がなければ、本体アプリの案内を出さない")
  func unknownHostApp() {
    let availability = Self.availability(
      Self.environment(sharedContainer: .available(hostApp: nil), network: .offline))

    #expect(availability.actions == [.typing, .sharedResult, .openHostApp])
    #expect(availability.notices.isEmpty)
  }

  @Test(
    "iAC-07: 鮮度の上限を超えた、または観測時刻が未来の本体アプリの状態は案内に使わない",
    arguments: [
      (-3600.0, true),  // ちょうど上限
      (-3601.0, false),  // 上限を超えた
      (0.0, true),
      (1.0, false),  // 時刻の巻き戻り
    ])
  func staleHostApp(_ offset: TimeInterval, _ used: Bool) {
    let host = Self.host(
      observedAt: Self.now.addingTimeInterval(offset), deniedPermissions: [.microphone])
    let availability = KeyboardAvailability(
      Self.environment(sharedContainer: .available(hostApp: host)), at: Self.now,
      hostAppStatusMaximumAge: .seconds(3600))

    #expect(availability.actions == [.typing, .sharedResult, .openHostApp])
    #expect(availability.notices == (used ? [.permissionDenied(.microphone)] : []))
  }

  @Test("iAC-07: 本体アプリの状態は App Group に残すため、符号化して戻しても同じ値になる")
  func hostAppStatusRoundTrip() throws {
    let host = Self.host(
      deniedPermissions: [.microphone, .speechRecognition], speechModel: .notDownloaded,
      usesCloudRefinement: false)

    let decoded = try JSONDecoder().decode(
      HostAppStatus.self, from: JSONEncoder().encode(host))

    #expect(decoded == host)
  }

  @Test("iAC-07: 鮮度の上限の既定値は1時間")
  func defaultMaximumAge() {
    #expect(KeyboardAvailability.defaultHostAppStatusMaximumAge == .seconds(3600))
  }
}
