import Testing

@testable import UtterCore

struct InsertionPolicyTests {
  private static let target = InsertionTargetID(rawValue: "window-1/field-3")
  private let allRoutes = Set(InsertionRoute.allCases)

  private func plan(
    _ policy: InsertionPolicy = InsertionPolicy(),
    app: String? = "com.example.editor",
    verification: InsertionTargetVerification = .compare(recorded: target),
    permitted: Set<InsertionRoute>? = nil
  ) -> InsertionPlan {
    policy.plan(app: app, verification: verification, permittedRoutes: permitted ?? allRoutes)
  }

  private func next(_ plan: InsertionPlan, _ attempts: [InsertionResult]) -> InsertionNextStep {
    plan.nextStep(after: attempts, currentTarget: Self.target)
  }

  // MARK: INS-01

  @Test(
    "INS-01: 入力対象が記録できない・消失した・変わった場合はプレビューへ退避する",
    arguments: [
      (nil, InsertionTargetID(rawValue: "a"), InsertionPreviewReason.targetUnknown),
      (InsertionTargetID(rawValue: "a"), nil, .targetMissing),
      (InsertionTargetID(rawValue: "a"), InsertionTargetID(rawValue: "b"), .targetChanged),
    ] as [(InsertionTargetID?, InsertionTargetID?, InsertionPreviewReason)])
  func previewWhenTargetDiffers(
    _ recorded: InsertionTargetID?, _ current: InsertionTargetID?, _ reason: InsertionPreviewReason
  ) {
    let plan = plan(verification: .compare(recorded: recorded))

    #expect(plan.nextStep(after: [], currentTarget: current) == .showPreview(reason))
  }

  @Test("INS-01: 入力対象が同じなら自動挿入する")
  func insertsWhenTargetMatches() {
    #expect(next(plan(), []) == .tryRoute(.accessibility))
  }

  @Test("INS-01: 経路を切り替える前に入力対象が変わったら、次の経路を試さずに退避する")
  func revalidatesBeforeEachRoute() {
    let plan = plan()
    let moved = InsertionTargetID(rawValue: "window-2/field-1")

    #expect(
      plan.nextStep(after: [.failed(.accessibility)], currentTarget: moved)
        == .showPreview(.targetChanged))
    #expect(
      plan.nextStep(after: [.failed(.accessibility)], currentTarget: nil)
        == .showPreview(.targetMissing))
  }

  @Test("iOS-06: 利用者が挿入先を確認した場合は同一性を比べずに挿入する")
  func userConfirmedTarget() {
    let policy = InsertionPolicy(defaultRoutes: [.textDocumentProxy])
    let plan = plan(
      policy, app: nil, verification: .confirmedByUser, permitted: [.textDocumentProxy])

    #expect(plan.nextStep(after: [], currentTarget: nil) == .tryRoute(.textDocumentProxy))
    #expect(
      plan.nextStep(after: [.verified(.textDocumentProxy)], currentTarget: nil)
        == .finish(.verified(.textDocumentProxy)))
  }

  @Test("INS-01: 入力対象の識別子の文字列表現に値を出さない")
  func redactsTargetID() {
    let id = InsertionTargetID(rawValue: "秘密のウィンドウ")

    for output in [String(describing: id), String(reflecting: id)] {
      #expect(!output.contains("秘密"))
    }
  }

  // MARK: INS-02

  @Test("INS-02: 既定の経路は Accessibility → Pasteboard → CGEvent の順")
  func defaultRouteOrder() {
    #expect(InsertionPolicy.defaultRoutes == [.accessibility, .pasteboard, .keyEvents])
    #expect(plan().routes == [.accessibility, .pasteboard, .keyEvents])
  }

  @Test("INS-02: 失敗したら次の経路を試し、すべて失敗したらプレビューへ退避する")
  func fallsThroughRoutesOnFailure() {
    let plan = plan()

    #expect(next(plan, [.failed(.accessibility)]) == .tryRoute(.pasteboard))
    #expect(next(plan, [.failed(.accessibility), .failed(.pasteboard)]) == .tryRoute(.keyEvents))
    #expect(
      next(plan, [.failed(.accessibility), .failed(.pasteboard), .failed(.keyEvents)])
        == .showPreview(.allRoutesFailed))
  }

  @Test("INS-02: 許可のない経路は使わず、使える経路がなければプレビューへ退避する")
  func usesOnlyPermittedRoutes() {
    #expect(plan(permitted: [.accessibility, .keyEvents]).routes == [.accessibility, .keyEvents])
    #expect(next(plan(permitted: []), []) == .showPreview(.noAvailableRoute))
  }

  @Test("AC-20: アプリ別の既定経路で上書きでき、重複した経路は1回だけ試す。識別子は大文字・小文字を区別しない")
  func appProfileOverridesRoutes() {
    let policy = InsertionPolicy(profiles: [
      "com.example.Chat": AppInsertionProfile(routes: [.pasteboard, .pasteboard, .accessibility])
    ])

    #expect(plan(policy, app: "COM.EXAMPLE.CHAT").routes == [.pasteboard, .accessibility])
    #expect(plan(policy, app: "com.example.other").routes == InsertionPolicy.defaultRoutes)
    #expect(plan(policy, app: nil).routes == InsertionPolicy.defaultRoutes)
  }

  // MARK: INS-03

  @Test("INS-03: 成功不明なら再試行せずに終える", arguments: InsertionRoute.allCases)
  func doesNotRetryWhenUnconfirmed(_ route: InsertionRoute) {
    #expect(next(plan(), [.unconfirmed(route)]) == .finish(.unconfirmed(route)))
  }

  @Test(
    "INS-03: 試行結果の並びによらず、入った可能性があれば再試行しない",
    arguments: [
      (
        [InsertionResult.failed(.accessibility), .unconfirmed(.pasteboard)],
        InsertionNextStep.finish(.unconfirmed(.pasteboard))
      ),
      ([.unconfirmed(.accessibility), .verified(.pasteboard)], .finish(.verified(.pasteboard))),
      (
        [.unconfirmed(.accessibility), .preview(.targetChanged)],
        .finish(.unconfirmed(.accessibility))
      ),
      ([.preview(.targetChanged), .failed(.accessibility)], .showPreview(.targetChanged)),
      // 計画にない経路の失敗は次の経路の選択に使わない
      ([.failed(.textDocumentProxy)], .tryRoute(.accessibility)),
      // 計画にない経路でも、入った可能性があれば終える
      ([.unconfirmed(.textDocumentProxy)], .finish(.unconfirmed(.textDocumentProxy))),
      // 同じ経路の失敗の重複は1回として扱う
      ([.failed(.accessibility), .failed(.accessibility)], .tryRoute(.pasteboard)),
    ])
  func attemptSequences(_ attempts: [InsertionResult], _ expected: InsertionNextStep) {
    #expect(next(plan(), attempts) == expected)
  }

  @Test("INS-03: 挿入した可能性がある結果を区別する")
  func mayHaveInserted() {
    #expect(InsertionResult.verified(.accessibility).mayHaveInserted)
    #expect(InsertionResult.unconfirmed(.pasteboard).mayHaveInserted)
    #expect(!InsertionResult.failed(.keyEvents).mayHaveInserted)
    #expect(!InsertionResult.preview(.targetMissing).mayHaveInserted)
  }

  @Test(
    "INS-03: 末尾の空白・改行はどのアプリでも挿入しない",
    arguments: [("本文\n", "本文"), ("ls -la\n\r\n", "ls -la"), ("ls\n ", "ls"), ("a  b", "a  b")])
  func trimsTrailingNewlines(_ input: String, _ expected: String) {
    #expect(plan().preparedText(input) == expected)
  }

  @Test(
    "AC-08: ターミナル系では改行を含む文字列を自動挿入せずプレビューへ退避する",
    arguments: ["echo a\nb", "echo a\r\nb", "echo a\u{2028}b", "a\u{0085}b"])
  func terminalRejectsMultiline(_ input: String) {
    let policy = InsertionPolicy(profiles: [
      "com.apple.Terminal": AppInsertionProfile(isTerminal: true)
    ])
    let terminal = plan(policy, app: "com.apple.terminal")

    #expect(terminal.preparedText(input) == nil)
    #expect(terminal.preparedText("ls -la\n") == "ls -la")
    #expect(plan(policy, app: "com.example.editor").preparedText(input) != nil)
  }

  // MARK: INS-05

  @Test(
    "INS-05: 読み戻しで一致したときだけ確認済みにし、送信後の失敗や読み戻し不可は成功不明にする",
    arguments: [
      (
        InsertionResponse.succeeded, InsertionReadBack.matches,
        InsertionResult.verified(.accessibility)
      ),
      (.failedAfterSend, .matches, .verified(.accessibility)),
      (.rejectedBeforeSend, .matches, .verified(.accessibility)),
      (.succeeded, .unchanged, .failed(.accessibility)),
      (.failedAfterSend, .unchanged, .failed(.accessibility)),
      (.rejectedBeforeSend, .unchanged, .failed(.accessibility)),
      (.succeeded, .differs, .unconfirmed(.accessibility)),
      (.failedAfterSend, .differs, .unconfirmed(.accessibility)),
      (.rejectedBeforeSend, .differs, .unconfirmed(.accessibility)),
      (.succeeded, .unavailable, .unconfirmed(.accessibility)),
      (.failedAfterSend, .unavailable, .unconfirmed(.accessibility)),
      (.rejectedBeforeSend, .unavailable, .failed(.accessibility)),
    ])
  func classifiesByReadBack(
    _ response: InsertionResponse, _ readBack: InsertionReadBack, _ expected: InsertionResult
  ) {
    #expect(
      InsertionResult.classify(route: .accessibility, response: response, readBack: readBack)
        == expected)
  }

  // MARK: INS-04

  @Test("INS-04: 他のアプリがクリップボードを更新していなければ復元できる")
  func restoresClipboardWhenUnchanged() {
    let policy = ClipboardRestorePolicy(changeCountAfterWrite: 42)

    #expect(policy.allowsRestore(currentChangeCount: 42))
    #expect(!policy.allowsRestore(currentChangeCount: 43))
    #expect(!policy.allowsRestore(currentChangeCount: 41))
  }
}
