import Testing

@testable import UtterCore

struct SensitiveInputPolicyTests {
  private static let policy = SensitiveInputPolicy(
    sensitiveApps: ["COM.EXAMPLE.VAULT", "com.example.both"],
    excludedApps: [" com.example.Private ", "com.example.both"])

  /// アプリの識別子と、それだけで生じる抑止の理由
  private static let apps: [(String?, Set<SensitiveInputReason>)] = [
    ("com.example.editor", []),
    ("com.example.vault", [.sensitiveApp]),
    ("com.example.private", [.excludedApp]),
    ("com.example.both", [.sensitiveApp, .excludedApp]),
    ("", [.undetermined]),
    (" \n", [.undetermined]),
    (nil, [.undetermined]),
  ]

  private static func reasons(_ signal: SensitiveSignal, on reason: SensitiveInputReason)
    -> Set<SensitiveInputReason>
  {
    switch signal {
    case .on: [reason]
    case .off: []
    case .unknown: [.undetermined]
    }
  }

  /// 入力の全組み合わせ（3 × 3 × 7 = 63 通り）と、期待する抑止の理由
  static let cases: [(SensitiveInputContext, Set<SensitiveInputReason>)] =
    SensitiveSignal.allCases.flatMap { field in
      SensitiveSignal.allCases.flatMap { event in
        apps.map { app, appReasons in
          (
            SensitiveInputContext(secureField: field, secureEventInput: event, app: app),
            reasons(field, on: .secureField).union(reasons(event, on: .secureEventInput))
              .union(appReasons)
          )
        }
      }
    }

  @Test("AC-12: 全組み合わせで、該当・不明が1つでもあれば録音・送信・履歴をすべて抑止する", arguments: cases)
  func allCombinations(_ context: SensitiveInputContext, _ expected: Set<SensitiveInputReason>) {
    let decision = Self.policy.decide(context)
    let allowed = expected.isEmpty

    #expect(decision.reasons == expected)
    #expect(decision.allowsRecording == allowed)
    #expect(decision.allowsCloudTransmission == allowed)
    #expect(decision.allowsHistory == allowed)
  }

  @Test("AC-12: 全組み合わせのうち許可はすべて該当しないと判定できた場合だけ")
  func onlyAllClearIsAllowed() {
    let allowed = Self.cases.filter { Self.policy.decide($0.0).allowsRecording }

    #expect(allowed.count == 1)
    #expect(
      allowed.first?.0
        == SensitiveInputContext(
          secureField: .off, secureEventInput: .off, app: "com.example.editor"))
  }

  @Test("AC-12: パスワード欄では録音・送信・履歴を抑止する")
  func suppressesPasswordField() {
    let decision = Self.policy.decide(
      SensitiveInputContext(secureField: .on, secureEventInput: .off, app: "com.example.editor"))

    #expect(!decision.allowsRecording)
    #expect(!decision.allowsCloudTransmission)
    #expect(!decision.allowsHistory)
    #expect(decision.reasons == [.secureField])
  }

  @Test("AC-12: 除外アプリ・機密アプリは前後の空白を除き、大文字・小文字を区別せずに照合する")
  func normalizesAppIdentifiers() {
    #expect(Self.policy.excludedApps == ["com.example.private", "com.example.both"])
    #expect(Self.policy.sensitiveApps == ["com.example.vault", "com.example.both"])
    #expect(SensitiveInputPolicy(excludedApps: ["  ", ""]).excludedApps.isEmpty)
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
