import Foundation
import Testing
import UtterAI
import UtterCore
import UtterText

/// Edit Mode のアプリ側の流れ（AC-14）。AX・パネル・クラウド AI は Stub に置き換える。
@MainActor
struct EditModeCoordinatorTests {
  private static let target = InsertionTargetID(rawValue: "edited")
  private static let app = "com.example.editor"
  /// 「明日は会議です。」の「会議」（UTF-16 で 3〜4）を選択した入力欄
  private static let value = "明日は会議です。"
  private static let selected = FieldSnapshot.Selection(location: 3, length: 2)

  let log = InsertionLog()
  let field = FakeTextField(
    value: EditModeCoordinatorTests.value, selection: EditModeCoordinatorTests.selected)
  let inspector = StubInspector(
    targets: [
      FocusedInsertionTarget(
        id: EditModeCoordinatorTests.target, app: EditModeCoordinatorTests.app, secureField: .off)
    ],
    recorded: EditModeCoordinatorTests.target)
  let permissions = StubPermissions()
  let presenter = StubEditPresenter()
  let clock: StubClock
  let editField: StubEditField
  let provider = StubAIProvider(behavior: .respond("打ち合わせ"), destination: .claude)
  var consent = ConsentState()

  init() {
    clock = StubClock(log: log)
    editField = StubEditField(field: field, target: Self.target, log: log)
    consent.grant(.transmission(.editSelection(.claude)))
  }

  private func coordinator(consent: ConsentState? = nil) throws -> EditModeCoordinator {
    let state = consent ?? self.consent
    return EditModeCoordinator(
      inspector: inspector,
      field: editField,
      permissions: permissions,
      presenter: presenter,
      clock: clock,
      router: try EditRouter(provider: provider),
      consent: { state })
  }

  /// 開始 → 音声指示 → 差分プレビューまで進める
  private func proposed(_ coordinator: EditModeCoordinator) async {
    #expect(coordinator.begin() == nil)
    #expect(await coordinator.submit(instruction: "会議を打ち合わせにして") == .proposed)
  }

  // MARK: 開始

  @Test("AC-14: 選択がなければ始めず、送信しない")
  func noSelection() async throws {
    field.selection = FieldSnapshot.Selection(location: 3, length: 0)
    let coordinator = try coordinator()

    #expect(coordinator.begin() == .noSelection)
    #expect(await coordinator.submit(instruction: "直して") == .noActiveEdit)
    #expect(presenter.notices == [.couldNotStart(.noSelection)])
    #expect(await provider.editCallCount == 0)
  }

  @Test("AC-14: 選択範囲・値を読めない入力欄では始めない")
  func selectionUnreadable() throws {
    editField.selectedTextReadable = false
    #expect(try coordinator().begin() == .selectionUnreadable)

    editField.selectedTextReadable = true
    field.readable = false
    #expect(try coordinator().begin() == .selectionUnreadable)
  }

  @Test("AC-14 / 7章: パスワード欄では選択範囲を読まない")
  func secureField() throws {
    inspector.targets = [FocusedInsertionTarget(id: Self.target, app: Self.app, secureField: .on)]

    #expect(try coordinator().begin() == .sensitiveInput([.secureField]))
  }

  @Test("AC-14 / PERM-02: Accessibility が未許可なら始めない")
  func accessibilityNotTrusted() throws {
    permissions.accessibility = false

    #expect(try coordinator().begin() == .accessibilityNotTrusted)
  }

  // MARK: 音声指示

  @Test("AC-06: 選択テキストの送信に同意していなければ送らない")
  func consentNotGranted() async throws {
    var consent = ConsentState()
    consent.grant(.transmission(.textRefinement(.claude)))
    let coordinator = try coordinator(consent: consent)

    #expect(coordinator.begin() == nil)
    let result = await coordinator.submit(instruction: "会議を打ち合わせにして")

    #expect(result == .notEdited(.consentNotGranted))
    #expect(await provider.editCallCount == 0)
    #expect(presenter.notices == [.notEdited(.consentNotGranted)])
    #expect(field.value == Self.value)
  }

  @Test("AC-12: 音声指示を送る時点で選択範囲の入力欄がパスワード欄になっていたら送らない")
  func secureFieldAtSubmit() async throws {
    let coordinator = try coordinator()
    #expect(coordinator.begin() == nil)
    editField.secure = .on

    let result = await coordinator.submit(instruction: "会議を打ち合わせにして")

    #expect(result == .notEdited(.sensitiveInputSuppressed))
    #expect(await provider.editCallCount == 0)
    #expect(presenter.notices == [.notEdited(.sensitiveInputSuppressed)])
    #expect(presenter.proposals.isEmpty)
    #expect(field.value == Self.value)
  }

  @Test(
    "AC-12: 音声指示を送る時点でセキュア入力が有効・判定できなければ送らない",
    arguments: [
      SensitiveSignal.on, .unknown,
    ])
  func secureEventInputAtSubmit(_ signal: SensitiveSignal) async throws {
    let coordinator = try coordinator()
    #expect(coordinator.begin() == nil)
    inspector.secure = signal

    #expect(
      await coordinator.submit(instruction: "会議を打ち合わせにして")
        == .notEdited(.sensitiveInputSuppressed))
    #expect(await provider.editCallCount == 0)
  }

  @Test("AC-14: 選択テキストと音声指示だけを送り、差分プレビューを表示する")
  func proposalShown() async throws {
    let coordinator = try coordinator()
    await proposed(coordinator)

    let request = try #require(await provider.receivedEditRequests.first)
    #expect(request.selection == "会議")
    #expect(request.instruction == "会議を打ち合わせにして")
    #expect(presenter.proposals == ["打ち合わせ"])
    #expect(field.value == Self.value)
    #expect(log.sentInsertions.isEmpty)
  }

  @Test("AC-14: 編集に失敗したら選択範囲を変えずに通知し、同じ選択でやり直せる")
  func editFailed() async throws {
    await provider.setBehavior(.fail(.timeout))
    let coordinator = try coordinator()
    #expect(coordinator.begin() == nil)

    #expect(await coordinator.submit(instruction: "直して") == .notEdited(.providerFailed(.timeout)))
    #expect(presenter.notices == [.notEdited(.providerFailed(.timeout))])
    #expect(presenter.proposals.isEmpty)
    #expect(field.value == Self.value)

    await provider.setBehavior(.respond("打ち合わせ"))
    #expect(await coordinator.submit(instruction: "直して") == .proposed)
  }

  @Test("AC-14: 応答を待つ間にキャンセルしたら、届いた編集案を表示しない")
  func cancelledWhileRequesting() async throws {
    await provider.setBehavior(.respond("打ち合わせ"), delay: .milliseconds(50))
    let coordinator = try coordinator()
    #expect(coordinator.begin() == nil)

    let pending = Task { await coordinator.submit(instruction: "直して") }
    // 送信して応答を待っている間にキャンセルする
    while await provider.editCallCount == 0 {
      await Task.yield()
    }
    coordinator.cancel()

    #expect(await pending.value == .superseded)
    #expect(presenter.proposals.isEmpty)
    #expect(await coordinator.commit() == .noProposal)
    #expect(field.value == Self.value)
  }

  // MARK: 確定・キャンセル

  @Test("AC-14: 確定すると選択範囲を置き換え、読み戻しで確かめる")
  func commitReplaces() async throws {
    let coordinator = try coordinator()
    await proposed(coordinator)

    #expect(await coordinator.commit() == .replaced(.verified(.accessibility)))
    #expect(field.value == "明日は打ち合わせです。")
    #expect(log.sentInsertions == [.axInsert("打ち合わせ")])
    #expect(presenter.events.contains(.dismiss))
    #expect(presenter.notices.last == .replaced(verified: true))
    #expect(coordinator.canUndo)
  }

  @Test("AC-14: キャンセルすると選択範囲を変えずに終える")
  func cancelKeepsSelection() async throws {
    let coordinator = try coordinator()
    await proposed(coordinator)

    coordinator.cancel()

    #expect(presenter.events.last == .dismiss)
    #expect(await coordinator.commit() == .noProposal)
    #expect(field.value == Self.value)
    #expect(log.sentInsertions.isEmpty)
    #expect(!coordinator.canUndo)
  }

  @Test("AC-14 / AC-09: 書き込んでも変化がなければ、編集案を退避する")
  func replacementFailed() async throws {
    field.axBehavior = .ignored
    let coordinator = try coordinator()
    await proposed(coordinator)

    #expect(await coordinator.commit() == .fallback(.replacementFailed))
    #expect(presenter.fallbacks == [.fallback("打ち合わせ", .replacementFailed)])
    #expect(field.value == Self.value)
    #expect(!coordinator.canUndo)
  }

  @Test("AC-14 / AC-09: 書き込みを拒否されたら、編集案を退避する")
  func replacementRejected() async throws {
    field.axSettable = false
    let coordinator = try coordinator()
    await proposed(coordinator)

    #expect(await coordinator.commit() == .fallback(.replacementFailed))
    #expect(presenter.fallbacks == [.fallback("打ち合わせ", .replacementFailed)])
  }

  @Test("AC-14: 確認中に選択範囲の文字列が書き換えられたら、上書きせずに退避する")
  func selectionChangedBeforeCommit() async throws {
    let coordinator = try coordinator()
    await proposed(coordinator)
    field.value = "明日は会合です。"

    #expect(await coordinator.commit() == .fallback(.selectionChanged))
    #expect(log.sentInsertions.isEmpty)
    #expect(field.value == "明日は会合です。")
  }

  @Test("AC-14: 選択範囲だけ動いていれば、元の範囲を選び直して置き換える")
  func reselectsMovedSelection() async throws {
    let coordinator = try coordinator()
    await proposed(coordinator)
    field.selection = FieldSnapshot.Selection(location: 0, length: 0)

    #expect(await coordinator.commit() == .replaced(.verified(.accessibility)))
    #expect(editField.selections == [Self.selected])
    #expect(field.value == "明日は打ち合わせです。")
  }

  @Test("AC-14: 選び直せなければ、別の位置へ書き込まずに退避する")
  func cannotReselect() async throws {
    editField.selectable = false
    let coordinator = try coordinator()
    await proposed(coordinator)
    field.selection = FieldSnapshot.Selection(location: 0, length: 0)

    #expect(await coordinator.commit() == .fallback(.cannotReselect))
    #expect(log.sentInsertions.isEmpty)
  }

  @Test("AC-14 / 7章: 確定時にセキュア入力が有効なら書き込まない")
  func secureInputAtCommit() async throws {
    let coordinator = try coordinator()
    await proposed(coordinator)
    inspector.secure = .on

    #expect(await coordinator.commit() == .fallback(.sensitiveInput([.secureEventInput])))
    #expect(log.sentInsertions.isEmpty)
  }

  // MARK: 元に戻す

  @Test("AC-14: 確定した Edit を元の選択テキストへ戻せる（一度だけ）")
  func undoRestores() async throws {
    let coordinator = try coordinator()
    await proposed(coordinator)
    _ = await coordinator.commit()

    #expect(await coordinator.undo() == .restored(.verified(.accessibility)))
    #expect(field.value == Self.value)
    #expect(presenter.notices.last == .restored(verified: true))
    #expect(await coordinator.undo() == .nothingToUndo)
  }

  @Test("AC-14: アプリの ⌘Z ですでに戻っていれば何もしない")
  func undoAlreadyRestoredByApp() async throws {
    let coordinator = try coordinator()
    await proposed(coordinator)
    _ = await coordinator.commit()
    field.value = Self.value

    #expect(await coordinator.undo() == .alreadyRestored)
    #expect(log.sentInsertions == [.axInsert("打ち合わせ")])
  }

  @Test("AC-14: 確定後に書き換えられていたら上書きせず、元のテキストを退避する")
  func undoAfterUserEdit() async throws {
    let coordinator = try coordinator()
    await proposed(coordinator)
    _ = await coordinator.commit()
    field.value = "明後日は打ち合わせ"

    #expect(await coordinator.undo() == .fallback(.changedSinceCommit))
    #expect(presenter.fallbacks == [.fallback("会議", .changedSinceCommit)])
    #expect(field.value == "明後日は打ち合わせ")
  }

  @Test("AC-14: 元に戻す書き込みが反映されなければ、元のテキストを退避する")
  func undoWriteFailed() async throws {
    let coordinator = try coordinator()
    await proposed(coordinator)
    _ = await coordinator.commit()
    field.axBehavior = .ignored

    #expect(await coordinator.undo() == .fallback(.replacementFailed))
    #expect(presenter.fallbacks == [.fallback("会議", .replacementFailed)])
  }

  @Test("AC-14: 新しい Edit を始めると、前の Edit は元に戻せなくなる")
  func beginDropsUndo() async throws {
    let coordinator = try coordinator()
    await proposed(coordinator)
    _ = await coordinator.commit()

    field.selection = FieldSnapshot.Selection(location: 0, length: 2)
    #expect(coordinator.begin() == nil)

    #expect(!coordinator.canUndo)
    #expect(await coordinator.undo() == .nothingToUndo)
  }

  @Test("AC-14: 確定テキストが元のテキストを含み、確定後に書き換えられていれば、戻ったとみなさない")
  func undoPrefixEditChanged() async throws {
    await provider.setBehavior(.respond("会議室"))
    let coordinator = try coordinator()
    await proposed(coordinator)
    _ = await coordinator.commit()
    #expect(field.value == "明日は会議室です。")
    field.value = "明日は会議Xです。"

    #expect(await coordinator.undo() == .fallback(.changedSinceCommit))
    #expect(field.value == "明日は会議Xです。")
  }

  @Test("AC-14: 選び直せない入力欄では、書き換えられていたとは通知しない")
  func undoCannotReselect() async throws {
    let coordinator = try coordinator()
    await proposed(coordinator)
    _ = await coordinator.commit()
    editField.selectable = false

    #expect(await coordinator.undo() == .fallback(.cannotReselect))
    #expect(presenter.fallbacks == [.fallback("会議", .cannotReselect)])
  }

  @Test("AC-14: 元に戻すときに値を読めなければ、元のテキストを退避する")
  func undoTargetMissing() async throws {
    let coordinator = try coordinator()
    await proposed(coordinator)
    _ = await coordinator.commit()
    field.readable = false

    #expect(await coordinator.undo() == .fallback(.targetMissing))
    #expect(presenter.fallbacks == [.fallback("会議", .targetMissing)])
  }

  @Test("AC-14: 確定の読み戻しを待つ間に次の Edit を始めたら、前の Edit を元に戻せる Edit に残さない")
  func beginDuringCommitReadBack() async throws {
    field.axBehavior = .ignored
    let coordinator = try coordinator()
    await proposed(coordinator)
    clock.onSleep = { [field] in
      field.value = "明日は打ち合わせです。"
      field.selection = FieldSnapshot.Selection(location: 0, length: 2)
      #expect(coordinator.begin() == nil)
    }

    #expect(await coordinator.commit() == .replaced(.verified(.accessibility)))
    #expect(!coordinator.canUndo)
    #expect(coordinator.hasActiveEdit)
  }

  // MARK: やり直し・重複

  @Test("AC-14: 確認中に音声指示をやり直すと、編集案を置き換える")
  func resubmitReplacesProposal() async throws {
    let coordinator = try coordinator()
    await proposed(coordinator)
    await provider.setBehavior(.respond("面談"))

    #expect(await coordinator.submit(instruction: "面談にして") == .proposed)
    #expect(presenter.proposals == ["打ち合わせ", "面談"])
    #expect(await coordinator.commit() == .replaced(.verified(.accessibility)))
    #expect(field.value == "明日は面談です。")
  }

  @Test("AC-14: 応答を待つ間の同じ Edit への送信は受け付けず、始め直した Edit の送信は受け付ける")
  func busyAndSupersededByBegin() async throws {
    await provider.setBehavior(.respond("打ち合わせ"), delay: .milliseconds(50))
    let coordinator = try coordinator()
    #expect(coordinator.begin() == nil)

    let pending = Task { await coordinator.submit(instruction: "直して") }
    while await provider.editCallCount == 0 {
      await Task.yield()
    }
    #expect(await coordinator.submit(instruction: "直して") == .busy)
    #expect(coordinator.begin() == nil)
    await provider.setBehavior(.respond("面談"), delay: .zero)
    #expect(await coordinator.submit(instruction: "面談にして") == .proposed)

    #expect(await pending.value == .superseded)
    #expect(presenter.proposals == ["面談"])
  }

  @Test("AC-14: kAXSelectedText と値の範囲が食い違えば始めない")
  func selectedTextMismatch() throws {
    editField.selectedTextOverride = "会"

    #expect(try coordinator().begin() == .selectionUnreadable)
  }

  @Test("AC-14: 文字の境界でない範囲は切り出さない")
  func textAtNonCharacterBoundary() {
    // 「👍🏽」は UTF-16 で4単位の1文字
    #expect(EditModeCoordinator.text(in: "a👍🏽b", at: .init(location: 1, length: 2)) == nil)
    #expect(EditModeCoordinator.text(in: "a👍🏽b", at: .init(location: 1, length: 4)) == "👍🏽")
    #expect(EditModeCoordinator.text(in: "abc", at: .init(location: 2, length: 2)) == nil)
  }
}
