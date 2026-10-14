import Testing

@testable import UtterCore

struct SensitiveInputPolicyTests {
  private static let apps: [String?] = [
    "com.example.editor", "com.example.vault", "com.example.private", "", nil,
  ]
  private let policy = SensitiveInputPolicy(
    sensitiveApps: ["com.example.vault"], excludedApps: ["COM.EXAMPLE.PRIVATE"])

  @Test(
    "AC-12: 入力の全組み合わせで、該当・不明が1つでもあれば録音・送信・履歴をすべて抑止する",
    arguments: SensitiveSignal.allCases, SensitiveSignal.allCases)
  func allCombinations(_ secureField: SensitiveSignal, _ secureEventInput: SensitiveSignal) {
    for app in Self.apps {
      let context = SensitiveInputContext(
        secureField: secureField, secureEventInput: secureEventInput, app: app)
      let decision = policy.decide(context)

      var expected: Set<SensitiveInputReason> = []
      if secureField == .on { expected.insert(.secureField) }
      if secureEventInput == .on { expected.insert(.secureEventInput) }
      if secureField == .unknown || secureEventInput == .unknown || app == nil || app == "" {
        expected.insert(.undetermined)
      }
      if app == "com.example.vault" { expected.insert(.sensitiveApp) }
      if app == "com.example.private" { expected.insert(.excludedApp) }
      let allowed = expected.isEmpty

      #expect(decision.reasons == expected)
      #expect(decision.allowsRecording == allowed)
      #expect(decision.allowsCloudTransmission == allowed)
      #expect(decision.allowsHistory == allowed)
    }
  }

  @Test("AC-12: すべて該当しないと判定できたときだけ許可する")
  func allowsOnlyWhenAllClear() {
    let decision = policy.decide(
      SensitiveInputContext(secureField: .off, secureEventInput: .off, app: "com.example.editor"))

    #expect(decision.allowsRecording)
    #expect(decision.allowsCloudTransmission)
    #expect(decision.allowsHistory)
    #expect(decision.reasons.isEmpty)
  }

  @Test("AC-12: パスワード欄では抑止する")
  func suppressesPasswordField() {
    let decision = policy.decide(
      SensitiveInputContext(secureField: .on, secureEventInput: .off, app: "com.example.editor"))

    #expect(!decision.allowsRecording)
    #expect(decision.reasons == [.secureField])
  }

  @Test("AC-12: 除外アプリは利用者の設定で指定でき、大文字・小文字を区別しない")
  func userExcludedApps() {
    let policy = SensitiveInputPolicy(excludedApps: ["com.example.Diary"])
    let context = SensitiveInputContext(
      secureField: .off, secureEventInput: .off, app: "COM.EXAMPLE.DIARY")

    #expect(policy.decide(context).reasons == [.excludedApp])
    #expect(policy.excludedApps == ["com.example.diary"])
  }

  @Test("AC-12: 機密アプリの既定一覧は空")
  func noBundledSensitiveApps() {
    let policy = SensitiveInputPolicy()
    let context = SensitiveInputContext(
      secureField: .off, secureEventInput: .off, app: "com.example.vault")

    #expect(policy.sensitiveApps.isEmpty)
    #expect(policy.decide(context).allowsRecording)
  }
}
