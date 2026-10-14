import Testing

@testable import UtterCore

struct InsertionPolicyTests {
  private let target = InsertionTargetID(rawValue: "window-1/field-3")
  private let allRoutes = Set(InsertionRoute.allCases)

  private func plan(
    _ policy: InsertionPolicy = InsertionPolicy(),
    app: String? = "com.example.editor",
    recorded: InsertionTargetID?? = nil,
    current: InsertionTargetID?? = nil,
    permitted: Set<InsertionRoute>? = nil
  ) -> InsertionPlan {
    policy.plan(
      app: app,
      recordedTarget: recorded ?? target,
      currentTarget: current ?? target,
      permittedRoutes: permitted ?? allRoutes)
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
    let plan = plan(recorded: .some(recorded), current: .some(current))

    #expect(plan.previewReason == reason)
    #expect(plan.nextStep(after: []) == .showPreview(reason))
  }

  @Test("INS-01: 入力対象が同じなら自動挿入する")
  func insertsWhenTargetMatches() {
    let plan = plan()

    #expect(plan.previewReason == nil)
    #expect(plan.nextStep(after: []) == .tryRoute(.accessibility))
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

    #expect(plan.nextStep(after: [.failed(.accessibility)]) == .tryRoute(.pasteboard))
    #expect(
      plan.nextStep(after: [.failed(.accessibility), .failed(.pasteboard)]) == .tryRoute(.keyEvents)
    )
    #expect(
      plan.nextStep(after: [.failed(.accessibility), .failed(.pasteboard), .failed(.keyEvents)])
        == .showPreview(.allRoutesFailed))
  }

  @Test("INS-02: 許可のない経路は使わず、使える経路がなければプレビューへ退避する")
  func usesOnlyPermittedRoutes() {
    #expect(plan(permitted: [.accessibility, .keyEvents]).routes == [.accessibility, .keyEvents])

    let none = plan(permitted: [])
    #expect(none.routes.isEmpty)
    #expect(none.nextStep(after: []) == .showPreview(.noAvailableRoute))
  }

  @Test("AC-20: アプリ別の既定経路で上書きでき、重複した経路は1回だけ試す")
  func appProfileOverridesRoutes() {
    let policy = InsertionPolicy(profiles: [
      "com.example.chat": AppInsertionProfile(routes: [.pasteboard, .pasteboard, .accessibility])
    ])

    #expect(plan(policy, app: "com.example.chat").routes == [.pasteboard, .accessibility])
    #expect(plan(policy, app: "com.example.other").routes == InsertionPolicy.defaultRoutes)
    #expect(plan(policy, app: nil).routes == InsertionPolicy.defaultRoutes)
  }

  @Test("INS-02: iOS は UITextDocumentProxy だけを経路にできる")
  func iOSRoute() {
    let policy = InsertionPolicy(defaultRoutes: [.textDocumentProxy])
    let plan = plan(policy, app: nil, permitted: [.textDocumentProxy])

    #expect(plan.nextStep(after: []) == .tryRoute(.textDocumentProxy))
    #expect(
      plan.nextStep(after: [.verified(.textDocumentProxy)])
        == .finish(.verified(.textDocumentProxy)))
  }

  // MARK: INS-03

  @Test("INS-03: 成功不明なら再試行せずに終える", arguments: InsertionRoute.allCases)
  func doesNotRetryWhenUnconfirmed(_ route: InsertionRoute) {
    let plan = plan()

    #expect(plan.nextStep(after: [.unconfirmed(route)]) == .finish(.unconfirmed(route)))
    #expect(
      plan.nextStep(after: [.failed(.accessibility), .unconfirmed(.pasteboard)])
        == .finish(.unconfirmed(.pasteboard)))
  }

  @Test("INS-03: 確認済みなら終える")
  func finishesWhenVerified() {
    #expect(
      plan().nextStep(after: [.verified(.accessibility)]) == .finish(.verified(.accessibility)))
  }

  @Test("INS-03: プレビューへ退避した後は自動挿入しない")
  func stopsAfterPreview() {
    #expect(
      plan().nextStep(after: [.preview(.targetChanged)]) == .showPreview(.targetChanged))
  }

  @Test("INS-03: 挿入した可能性がある結果を区別する")
  func mayHaveInserted() {
    #expect(InsertionResult.verified(.accessibility).mayHaveInserted)
    #expect(InsertionResult.unconfirmed(.pasteboard).mayHaveInserted)
    #expect(!InsertionResult.failed(.keyEvents).mayHaveInserted)
    #expect(!InsertionResult.preview(.targetMissing).mayHaveInserted)
  }

  @Test("AC-08: ターミナル系では Enter を送らず、末尾の改行を挿入しない")
  func terminalDoesNotSendReturn() {
    let policy = InsertionPolicy(profiles: [
      "com.apple.Terminal": AppInsertionProfile(isTerminal: true)
    ])
    let terminal = plan(policy, app: "com.apple.Terminal")
    let editor = plan(policy, app: "com.example.editor")

    #expect(!terminal.allowsReturnKey)
    #expect(terminal.preparedText("ls -la\n\r\n") == "ls -la")
    #expect(terminal.preparedText("echo a\nb") == "echo a\nb")
    #expect(editor.allowsReturnKey)
    #expect(editor.preparedText("本文\n") == "本文\n")
  }

  // MARK: INS-05

  @Test(
    "INS-05: 成功応答だけを信用せず、読み戻しで確認できた場合だけ確認済みにする",
    arguments: [
      (true, InsertionReadBack.matches, InsertionResult.verified(.accessibility)),
      (false, .matches, .verified(.accessibility)),
      (true, .unchanged, .failed(.accessibility)),
      (false, .unchanged, .failed(.accessibility)),
      (true, .differs, .unconfirmed(.accessibility)),
      (false, .differs, .unconfirmed(.accessibility)),
      (true, .unavailable, .unconfirmed(.accessibility)),
      (false, .unavailable, .failed(.accessibility)),
    ])
  func classifiesByReadBack(
    _ reportedSuccess: Bool, _ readBack: InsertionReadBack, _ expected: InsertionResult
  ) {
    #expect(
      InsertionResult.classify(
        route: .accessibility, reportedSuccess: reportedSuccess, readBack: readBack) == expected)
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
