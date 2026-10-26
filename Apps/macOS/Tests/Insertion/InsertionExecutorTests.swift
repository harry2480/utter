import Foundation
import Testing
import UtterCore

/// 挿入の計画 → 実行の分岐（INS-01〜06, AC-08, AC-09, PERM-01/02）。OS の機能は Stub に置き換える。
@MainActor
struct InsertionExecutorTests {
  private static let recorded = InsertionTargetID(rawValue: "recorded")
  private static let other = InsertionTargetID(rawValue: "other")
  private static let app = "com.example.editor"
  private static let original = PasteboardSnapshot(
    items: [[PasteboardSnapshot.Entry(type: "public.png", data: Data([1, 2, 3]))]],
    unreadableTypeCount: 0)

  let log = InsertionLog()
  let field = FakeTextField(value: "abc")
  let inspector: StubInspector
  let pasteboard: StubPasteboard
  let keyEvents: StubKeyEvents
  let permissions = StubPermissions()
  let clock: StubClock
  let fieldAccess: StubFieldAccess

  init() {
    inspector = StubInspector(
      targets: [Self.target(Self.recorded)], recorded: Self.recorded)
    pasteboard = StubPasteboard(contents: Self.original, log: log)
    keyEvents = StubKeyEvents(field: field, pasteboard: pasteboard, log: log)
    clock = StubClock(log: log)
    fieldAccess = StubFieldAccess(field: field, target: Self.recorded, log: log)
  }

  private static func target(
    _ id: InsertionTargetID, app: String? = app, secureField: SensitiveSignal = .off
  ) -> FocusedInsertionTarget {
    FocusedInsertionTarget(id: id, app: app, secureField: secureField)
  }

  private func executor(
    policy: InsertionPolicy = InsertionPolicy(),
    sensitivePolicy: SensitiveInputPolicy = SensitiveInputPolicy(),
    timing: InsertionTiming = InsertionTiming()
  ) -> InsertionExecutor {
    InsertionExecutor(
      inspector: inspector,
      field: fieldAccess,
      pasteboard: pasteboard,
      keyEvents: keyEvents,
      permissions: permissions,
      preview: StubPreview(log: log),
      clock: clock,
      policy: policy,
      sensitivePolicy: sensitivePolicy,
      timing: timing)
  }

  /// Pasteboard 経路から試す計画（AX が使えないアプリの互換性表の行に当たる）
  private func pasteboardFirst() -> InsertionExecutor {
    executor(policy: InsertionPolicy(defaultRoutes: [.pasteboard, .keyEvents]))
  }

  private func insert(
    _ text: String = "こんにちは", executor: InsertionExecutor? = nil
  ) async -> InsertionReport {
    await (executor ?? self.executor()).insert(text, recordedTarget: inspector.recordTarget())
  }

  // MARK: INS-02 / INS-05

  @Test("INS-05: AX で書き込み、読み戻しで一致すれば確認済みとして終える")
  func accessibilityVerified() async {
    let report = await insert()

    #expect(report.outcome == .finished(.verified(.accessibility)))
    #expect(field.value == "abcこんにちは")
    #expect(log.sentInsertions == [.axInsert("こんにちは")])
    #expect(pasteboard.contents == Self.original)
    #expect(log.previews.isEmpty)
  }

  @Test("INS-05: 読み戻しで変化がなければ次の経路（Pasteboard）を試す")
  func fallsBackWhenUnchanged() async {
    field.axBehavior = .ignored

    let report = await insert()

    #expect(report.attempts == [.failed(.accessibility), .verified(.pasteboard)])
    #expect(report.outcome == .finished(.verified(.pasteboard)))
    #expect(field.value == "abcこんにちは")
    #expect(log.sentInsertions == [.axInsert("こんにちは"), .commandV])
  }

  @Test("INS-02: AX の書き込みができない入力欄は、送らずに次の経路を試す")
  func fallsBackWhenNotSettable() async {
    field.axSettable = false

    let report = await insert()

    #expect(report.attempts == [.failed(.accessibility), .verified(.pasteboard)])
    #expect(log.sentInsertions == [.commandV])
  }

  @Test("INS-03 / INS-05: 読み戻せない入力欄は成功不明として終え、再試行しない")
  func unreadableIsUnconfirmed() async {
    field.readable = false

    let report = await insert()

    #expect(report.outcome == .finished(.unconfirmed(.accessibility)))
    #expect(log.sentInsertions == [.axInsert("こんにちは")])
    #expect(log.previews.isEmpty)
  }

  @Test("INS-03 / INS-05: 一部だけ変わった場合は成功不明として終え、別の経路で入れ直さない")
  func partialIsUnconfirmed() async {
    field.axBehavior = .partial

    let report = await insert()

    #expect(report.outcome == .finished(.unconfirmed(.accessibility)))
    #expect(log.sentInsertions.count == 1)
  }

  @Test("INS-05: 読み戻しは一致するまで間隔を空けて読み直し、時間切れで判定する")
  func readBackPollsUntilTimeout() async {
    field.axBehavior = .ignored
    field.pasteBehavior = .ignored
    field.typeBehavior = .ignored
    let timing = InsertionTiming(
      readBackTimeout: .milliseconds(200), readBackInterval: .milliseconds(50),
      clipboardRestoreDelay: .milliseconds(10))
    let executor = executor(
      policy: InsertionPolicy(defaultRoutes: [.accessibility]), timing: timing)

    let report = await executor.insert("x", recordedTarget: Self.recorded)

    #expect(report.outcome == .preview(.plan(.allRoutesFailed)))
    #expect(log.events.filter { $0 == .sleep(.milliseconds(50)) }.count == 4)
  }

  @Test("INS-05: 読み戻しの時間切れは、AX の問い合わせにかかった時間も含めて判定する")
  func readBackDeadlineIncludesQueryTime() async {
    field.axBehavior = .ignored
    fieldAccess.readLatency = (clock, .milliseconds(500))
    let executor = executor(policy: InsertionPolicy(defaultRoutes: [.accessibility]))

    _ = await executor.insert("x", recordedTarget: Self.recorded)

    // 読み取りに 500 ミリ秒かかるため、0.5 秒（最初の読み取り）→ 1.05 秒 → 1.6 秒で締め切りの 1.5 秒を過ぎる。
    // 待ちの合計だけで数えると 30 回繰り返してしまう
    #expect(log.events.filter { $0 == .sleep(.milliseconds(50)) }.count == 2)
  }

  @Test("INS-05: 読み戻しの途中で取り消されたら成功不明として終え、次の経路を試さない")
  func cancellationDuringReadBackIsUnconfirmed() async {
    field.axBehavior = .ignored
    clock.onSleep = { withUnsafeCurrentTask { $0?.cancel() } }

    let report = await insert()

    #expect(report.outcome == .finished(.unconfirmed(.accessibility)))
    #expect(log.sentInsertions == [.axInsert("こんにちは")])
  }

  @Test("INS-05: 取り消された挿入は経路を試さずにプレビューへ退避する")
  func cancelledBeforeInsertion() async {
    withUnsafeCurrentTask { $0?.cancel() }

    let report = await insert()

    #expect(report.outcome == .preview(.cancelled))
    #expect(log.sentInsertions.isEmpty)
  }

  @Test("INS-03: AX の書き込みの直前に取り消されていたら書き込まず、プレビューへ退避する")
  func cancellationBeforeAccessibilityWrite() async {
    fieldAccess.onSnapshot = { withUnsafeCurrentTask { $0?.cancel() } }

    let report = await insert()

    #expect(report.attempts == [.failed(.accessibility)])
    #expect(report.outcome == .preview(.cancelled))
    #expect(log.sentInsertions.isEmpty)
    #expect(field.value == "abc")
  }

  @Test("INS-03: Cmd+V の直前に取り消されていたら送らずにクリップボードを戻し、プレビューへ退避する")
  func cancellationBeforeCommandV() async {
    pasteboard.onCapture = { withUnsafeCurrentTask { $0?.cancel() } }

    let report = await insert(executor: pasteboardFirst())

    #expect(report.attempts == [.failed(.pasteboard)])
    #expect(report.outcome == .preview(.cancelled))
    #expect(report.clipboardRestore == .restored)
    #expect(log.sentInsertions.isEmpty)
    #expect(pasteboard.contents == Self.original)
  }

  @Test("INS-03: キー入力の直前に取り消されていたら1文字も送らず、プレビューへ退避する")
  func cancellationBeforeKeyEvents() async {
    fieldAccess.onSnapshot = { withUnsafeCurrentTask { $0?.cancel() } }
    let policy = InsertionPolicy(defaultRoutes: [.keyEvents])

    let report = await insert("hello", executor: executor(policy: policy))

    #expect(report.attempts == [.failed(.keyEvents)])
    #expect(report.outcome == .preview(.cancelled))
    #expect(log.sentInsertions.isEmpty)
  }

  @Test("INS-04: 貼り付けの後に取り消されても、待ってからクリップボードを復元する")
  func cancellationDoesNotHurryRestore() async {
    clock.onSleep = { withUnsafeCurrentTask { $0?.cancel() } }
    field.pasteBehavior = .ignored

    let report = await insert(executor: pasteboardFirst())

    #expect(report.outcome == .finished(.unconfirmed(.pasteboard)))
    #expect(log.events.contains(.sleep(InsertionTiming().clipboardRestoreDelay)))
    #expect(log.events.last == .pasteboardRestore)
    #expect(!log.events.contains { if case .typed = $0 { true } else { false } })
  }

  // MARK: INS-01 / AC-09

  @Test("AC-09: 挿入直前の入力欄が録音開始時と違えば、何も送らずにプレビューへ退避する")
  func previewWhenTargetChanged() async {
    inspector.targets = [Self.target(Self.other)]

    let report = await insert()

    #expect(report.outcome == .preview(.plan(.targetChanged)))
    #expect(log.sentInsertions.isEmpty)
    #expect(log.previews == [.preview("こんにちは", .plan(.targetChanged))])
    #expect(pasteboard.changeCount == 0)
  }

  @Test("AC-09: 挿入先が消えていれば、何も送らずにプレビューへ退避する")
  func previewWhenTargetMissing() async {
    inspector.targets = [nil]

    let report = await insert()

    #expect(report.outcome == .preview(.plan(.targetMissing)))
    #expect(log.sentInsertions.isEmpty)
  }

  @Test("INS-01: 録音開始時の入力欄を記録できなければプレビューへ退避する")
  func previewWhenTargetUnknown() async {
    inspector.recorded = nil

    let report = await insert()

    #expect(report.outcome == .preview(.plan(.targetUnknown)))
    #expect(log.sentInsertions.isEmpty)
  }

  @Test("INS-01: 経路を切り替える前にもう一度確かめ、入力欄が変わっていれば次の経路を試さない")
  func revalidatesBeforeFallback() async {
    field.axBehavior = .ignored
    // 計画・AX の書き込みの直前までは同じ入力欄、次の経路の前に別の入力欄
    inspector.targets = [
      Self.target(Self.recorded), Self.target(Self.recorded), Self.target(Self.other),
    ]

    let report = await insert()

    #expect(report.attempts == [.failed(.accessibility)])
    #expect(report.outcome == .preview(.plan(.targetChanged)))
    #expect(log.sentInsertions == [.axInsert("こんにちは")])
    #expect(pasteboard.changeCount == 0)
  }

  @Test("INS-01: AX の書き込みの直前にフォーカスが移っていたら、記録した要素へも書き込まない")
  func accessibilityRevalidatesBeforeWrite() async {
    inspector.targets = [Self.target(Self.recorded), Self.target(Self.other)]

    let report = await insert()

    #expect(report.attempts == [.failed(.accessibility)])
    #expect(report.outcome == .preview(.plan(.targetChanged)))
    #expect(log.sentInsertions.isEmpty)
    #expect(field.value == "abc")
  }

  // MARK: 7章（セキュア入力）

  @Test(
    "AC-12: パスワード欄・セキュア入力・判定できない入力欄では挿入せずに退避する",
    arguments: [
      (SensitiveSignal.on, SensitiveSignal.off, SensitiveInputReason.secureField),
      (.off, .on, .secureEventInput),
      (.unknown, .off, .undetermined),
      (.off, .unknown, .undetermined),
    ] as [(SensitiveSignal, SensitiveSignal, SensitiveInputReason)])
  func noInsertionIntoSecureInput(
    _ secureField: SensitiveSignal, _ secureEventInput: SensitiveSignal,
    _ reason: SensitiveInputReason
  ) async {
    inspector.targets = [Self.target(Self.recorded, secureField: secureField)]
    inspector.secure = secureEventInput

    let report = await insert()

    #expect(report.outcome == .preview(.sensitiveInput([reason])))
    #expect(log.sentInsertions.isEmpty)
    #expect(pasteboard.changeCount == 0)
  }

  @Test("AC-12: 機密アプリ・除外アプリ・アプリが分からない場合は挿入せずに退避する")
  func noInsertionIntoSensitiveApps() async {
    let policy = SensitiveInputPolicy(
      sensitiveApps: ["com.example.passwords"], excludedApps: [Self.app])

    let excluded = await insert(executor: executor(sensitivePolicy: policy))
    inspector.targets = [Self.target(Self.recorded, app: nil)]
    let unknown = await insert()

    #expect(excluded.outcome == .preview(.sensitiveInput([.excludedApp])))
    #expect(unknown.outcome == .preview(.sensitiveInput([.undetermined])))
    #expect(log.sentInsertions.isEmpty)
  }

  @Test("AC-12: 経路を切り替える前にパスワード欄へ移っていれば、次の経路を試さない")
  func revalidatesSecureFieldBeforeFallback() async {
    field.axBehavior = .ignored
    inspector.targets = [
      Self.target(Self.recorded), Self.target(Self.recorded),
      Self.target(Self.recorded, secureField: .on),
    ]

    let report = await insert()

    #expect(report.outcome == .preview(.sensitiveInput([.secureField])))
    #expect(log.sentInsertions == [.axInsert("こんにちは")])
  }

  // MARK: PERM-01 / PERM-02

  @Test("PERM-02: Accessibility が未許可なら入力対象を確かめられないため、どの経路も使わずに退避する")
  func previewWithoutAccessibility() async {
    permissions.accessibility = false

    let report = await insert(executor: pasteboardFirst())

    #expect(report.outcome == .preview(.accessibilityNotTrusted))
    #expect(log.sentInsertions.isEmpty)
    #expect(pasteboard.changeCount == 0)
  }

  @Test("PERM-02: イベント送信が未許可なら Pasteboard / CGEvent 経路を使わない")
  func skipsEventRoutesWithoutPermission() async {
    permissions.postEvents = false
    field.axBehavior = .ignored

    let report = await insert()

    #expect(report.attempts == [.failed(.accessibility)])
    #expect(report.outcome == .preview(.plan(.allRoutesFailed)))
    #expect(pasteboard.changeCount == 0)
  }

  @Test("PERM-02: 使える経路がなければプレビューへ退避する")
  func previewWithoutAnyRoute() async {
    permissions.postEvents = false

    let report = await insert(executor: pasteboardFirst())

    #expect(report.outcome == .preview(.plan(.noAvailableRoute)))
    #expect(log.sentInsertions.isEmpty)
  }

  @Test("PERM-01: 使える経路は権限ごとに決まる")
  func permittedRoutes() {
    permissions.accessibility = true
    permissions.postEvents = false
    #expect(executor().permittedRoutes() == [.accessibility])

    permissions.accessibility = false
    permissions.postEvents = true
    #expect(executor().permittedRoutes() == [.pasteboard, .keyEvents])
  }

  // MARK: INS-03 / AC-08

  @Test("AC-08: ターミナル系のアプリへ改行を含む文字列は自動挿入せずに退避する")
  func multilineInTerminal() async {
    let policy = InsertionPolicy(profiles: [Self.app: AppInsertionProfile(isTerminal: true)])

    let report = await insert("ls\nrm -rf ~", executor: executor(policy: policy))

    #expect(report.outcome == .preview(.plan(.multilineInTerminal)))
    #expect(log.sentInsertions.isEmpty)
    #expect(log.previews == [.preview("ls\nrm -rf ~", .plan(.multilineInTerminal))])
  }

  @Test("AC-08: 本番の既定では、既知のターミナル系アプリに改行を含む文字列を自動挿入しない")
  func knownTerminalsAreTerminal() async {
    let policy = InsertionPolicy(profiles: KnownTerminalApps.profiles)
    inspector.targets = [Self.target(Self.recorded, app: "com.apple.terminal")]

    let report = await insert("ls\nrm -rf ~", executor: executor(policy: policy))

    #expect(report.outcome == .preview(.plan(.multilineInTerminal)))
    #expect(log.sentInsertions.isEmpty)
    for app in KnownTerminalApps.bundleIDs {
      // 経路の順は Phase 0 の判定前のため設定しない
      #expect(policy.profile(for: app) == AppInsertionProfile(routes: nil, isTerminal: true))
    }
  }

  @Test("AC-08: 末尾の改行は除いて挿入する（Enter として実行させない）")
  func trailingNewlineIsTrimmed() async {
    let policy = InsertionPolicy(profiles: [Self.app: AppInsertionProfile(isTerminal: true)])

    let report = await insert("ls -la\n", executor: executor(policy: policy))

    #expect(report.outcome == .finished(.verified(.accessibility)))
    #expect(log.sentInsertions == [.axInsert("ls -la")])
    #expect(field.value == "abcls -la")
  }

  @Test(
    "AC-08: CGEvent 経路では改行・Tab などの制御文字を含む文字列を送らない（送信・フォーカス移動になりうる）",
    arguments: ["一行目\n二行目", "a\r\nb", "a\tb", "a\u{2028}b", "a\u{1B}b"])
  func keyEventsNeverTypeControlCharacters(_ text: String) async {
    let policy = InsertionPolicy(defaultRoutes: [.keyEvents])

    let report = await insert(text, executor: executor(policy: policy))

    #expect(report.attempts == [.failed(.keyEvents)])
    #expect(report.outcome == .preview(.plan(.allRoutesFailed)))
    #expect(log.sentInsertions.isEmpty)
  }

  @Test("INS-01: CGEvent 経路で打っている途中にフォーカスが移ったら、残りを送らずに成功不明で終える")
  func keyEventsStopWhenFocusMoves() async {
    let policy = InsertionPolicy(defaultRoutes: [.keyEvents])
    // 計画・経路の直前・1文字目の直前までは同じ入力欄、2文字目の直前で別の入力欄
    inspector.targets = [
      Self.target(Self.recorded), Self.target(Self.recorded), Self.target(Self.other),
    ]

    let report = await insert("abc", executor: executor(policy: policy))

    #expect(log.sentInsertions == [.typed("a")])
    #expect(report.outcome == .finished(.unconfirmed(.keyEvents)))
  }

  @Test("INS-02: CGEvent 経路は改行を含まない文字列を送る")
  func keyEventsTypeSingleLine() async {
    let policy = InsertionPolicy(defaultRoutes: [.keyEvents])

    let report = await insert("hello", executor: executor(policy: policy))

    #expect(report.outcome == .finished(.verified(.keyEvents)))
    #expect(log.sentInsertions == [.typed("hello")])
  }

  @Test("AC-08: 空白・改行だけの文字列は何も送らず、プレビューも出さない")
  func nothingToInsert() async {
    let report = await insert(" \n\n")

    #expect(report.outcome == .nothingToInsert)
    #expect(log.events.isEmpty)
  }

  @Test("INS-03: 前の挿入の途中に頼まれた挿入は重ねずにプレビューへ退避する")
  func rejectsConcurrentInsertion() async {
    let executor = executor()
    var nested: InsertionReport?
    clock.onSleep = {
      nested = await executor.insert("二回目", recordedTarget: Self.recorded)
    }
    field.axBehavior = .ignored

    _ = await executor.insert("一回目", recordedTarget: Self.recorded)

    #expect(nested?.outcome == .preview(.insertionInProgress))
    #expect(log.previews.contains(.preview("二回目", .insertionInProgress)))
    #expect(!log.sentInsertions.contains(.axInsert("二回目")))
  }

  // MARK: INS-04 / INS-06

  @Test("INS-06: Pasteboard 経路は Transient / Concealed の印を付けて書き込む")
  func pasteboardMarkers() async {
    _ = await insert(executor: pasteboardFirst())

    #expect(
      log.events.contains(
        .pasteboardWrite(
          "こんにちは",
          markers: ["org.nspasteboard.TransientType", "org.nspasteboard.ConcealedType"])))
  }

  @Test("INS-04: 他のアプリが書き換えていなければ、貼り付けの後に元のクリップボードへ戻す")
  func restoresClipboard() async {
    let report = await insert(executor: pasteboardFirst())

    #expect(report.clipboardRestore == .restored)
    #expect(pasteboard.contents == Self.original)
    let events = log.events.filter {
      switch $0 {
      case .commandV, .pasteboardRestore: true
      default: false
      }
    }
    #expect(events == [.commandV, .pasteboardRestore])
  }

  @Test("INS-01: 退避・書き込みの後、Cmd+V の直前にフォーカスが移っていたら送らずに戻し、退避する")
  func pasteRevalidatesBeforeCommandV() async {
    // 計画・経路の直前までは同じ入力欄、Cmd+V の直前で別の入力欄
    inspector.targets = [
      Self.target(Self.recorded), Self.target(Self.other),
    ]

    let report = await insert(executor: pasteboardFirst())

    #expect(report.attempts == [.failed(.pasteboard)])
    #expect(report.outcome == .preview(.plan(.targetChanged)))
    #expect(report.clipboardRestore == .restored)
    #expect(log.sentInsertions.isEmpty)
    #expect(pasteboard.contents == Self.original)
  }

  @Test("AC-12: Cmd+V の直前にパスワード欄へ移っていたら送らない")
  func pasteRevalidatesSecureFieldBeforeCommandV() async {
    inspector.targets = [
      Self.target(Self.recorded), Self.target(Self.recorded, secureField: .on),
    ]

    let report = await insert(executor: pasteboardFirst())

    #expect(report.outcome == .preview(.sensitiveInput([.secureField])))
    #expect(log.sentInsertions.isEmpty)
    #expect(pasteboard.contents == Self.original)
  }

  @Test("INS-04: 貼り付けの後に他のアプリが書き換えたら復元しない")
  func skipsRestoreWhenChanged() async {
    clock.onSleep = { [pasteboard] in pasteboard.simulateOtherAppCopy("後からコピー") }

    let report = await insert(executor: pasteboardFirst())

    #expect(report.clipboardRestore == .skippedChanged)
    #expect(pasteboard.plainText == "後からコピー")
    #expect(!log.events.contains(.pasteboardRestore))
  }

  @Test("INS-04: 退避の途中で書き換えられたら、上書きせずに次の経路を試す")
  func abortsWhenChangedDuringCapture() async {
    pasteboard.changesDuringCapture = true

    let report = await insert(executor: pasteboardFirst())

    #expect(report.attempts == [.failed(.pasteboard), .verified(.keyEvents)])
    #expect(pasteboard.plainText == "other")
    #expect(!log.events.contains { if case .pasteboardWrite = $0 { true } else { false } })
  }

  @Test("INS-04: Cmd+V を送れなければすぐ元に戻し、次の経路を試す")
  func restoresWhenPasteFails() async {
    keyEvents.pasteSucceeds = false

    let report = await insert(executor: pasteboardFirst())

    #expect(report.attempts == [.failed(.pasteboard), .verified(.keyEvents)])
    #expect(report.clipboardRestore == .restored)
    #expect(pasteboard.contents == Self.original)
  }

  @Test("INS-04: 書き込みに失敗しても、退避した内容へ戻す")
  func restoresWhenWriteFails() async {
    pasteboard.writeSucceeds = false

    let report = await insert(executor: pasteboardFirst())

    #expect(report.attempts.first == .failed(.pasteboard))
    #expect(pasteboard.contents == Self.original)
  }

  @Test("INS-04: 読み戻せない入力欄では、読み戻しの時間切れと同じだけ待ってから復元する")
  func waitsBeforeRestoreWhenUnreadable() async {
    field.readable = false

    let report = await insert(executor: pasteboardFirst())

    #expect(report.outcome == .finished(.unconfirmed(.pasteboard)))
    let timing = InsertionTiming()
    let sleeps = log.events.filter { if case .sleep = $0 { true } else { false } }
    #expect(sleeps == [.sleep(timing.readBackTimeout), .sleep(timing.clipboardRestoreDelay)])
    #expect(log.events.last == .pasteboardRestore)
  }

  @Test("INS-04: 読み出せない種別があったら、一部だけ戻したと報告する")
  func reportsPartialRestore() async {
    pasteboard.contents.unreadableTypeCount = 1

    let report = await insert(executor: pasteboardFirst())

    #expect(report.clipboardRestore == .restoredPartially)
  }
}
