import UtterAI
import UtterCore
import UtterText

/// `EditModeCoordinator.submit(instruction:)` の結果。本文は含めない。
enum EditSubmitResult: Hashable, Sendable {
  /// 編集案を差分プレビューに表示した
  case proposed
  /// 編集案を得られなかった。選択範囲は変えず、同じ選択で音声指示をやり直せる
  case notEdited(EditFailureReason)
  /// アプリ側の条件（API キー・予算など）がそろわず、送らなかった。選択範囲は変えない
  case notSent(EditSendUnavailableReason)
  /// 進行中の Edit がない（始めていない・確定済み・キャンセル済み）
  case noActiveEdit
  /// 前の音声指示の応答を待っている
  case busy
  /// 応答を待つ間にキャンセル・やり直しされた。応答は捨てた
  case superseded
}

/// `EditModeCoordinator.commit()` の結果。
enum EditCommitResult: Hashable, Sendable {
  /// 選択範囲を置き換えた（`.verified` / `.unconfirmed(.accessibility)`）。成功不明でも再試行しない（INS-05）
  case replaced(InsertionResult)
  /// 置き換えず、編集案をコピーできるパネルへ退避した
  case fallback(EditFallbackCause)
  /// 確認中の編集案がない
  case noProposal
}

/// `EditModeCoordinator.undo()` の結果。
enum EditUndoResult: Hashable, Sendable {
  /// 元のテキストへ書き戻した（`.verified` / `.unconfirmed(.accessibility)`）
  case restored(InsertionResult)
  /// すでに元のテキストに戻っていた（アプリの ⌘Z など）。何もしていない
  case alreadyRestored
  /// 書き戻さず、元のテキストをコピーできるパネルへ退避した
  case fallback(EditFallbackCause)
  /// 元に戻せる Edit がない
  case nothingToUndo
}

/// Edit Mode のアプリ側の流れ（AC-14, 2.2節）。
///
/// 選択範囲の取得 → 音声指示 → 送信（`EditRequestSending`。本番は `EditRouter` で Claude へ）→ `EditSession` の差分プレビュー
/// → 確定で置き換え／キャンセル → 元に戻す、を進める。録音・STT と、録音のセッションとの調停は `EditModeController` が行う。
/// - 選択テキストは、フォーカス中の入力欄の `kAXSelectedTextAttribute` と、値・選択範囲から切り出した文字列が一致する場合だけ使う。
///   置き換えの読み戻しと元に戻す前の確認に値と範囲が要るため、読めない入力欄では始めない
/// - 送信の前に `EditSession.cloudTransmission(to:consent:)` で、送信先への選択テキストの送信の同意（`editSelection`）を
///   最新の同意状態で確かめる。送信側（`EditRouter`）も送る直前に同じ同意を確かめる（AC-06）
/// - 確定時は、録音開始時と同じ要素の同じ範囲に元の選択テキストが残っていることを確かめてから `kAXSelectedTextAttribute` に書き込み、
///   読み戻す。範囲の文字列が変わっていた・書き込めなかった・変化がなかった場合は、編集案をコピーできるパネルへ退避する
/// - 元に戻すときは、該当範囲が確定したテキストのままなら元の選択テキストへ書き戻す。書き換えられていれば上書きせず、元のテキストを退避する
/// - パスワード欄・セキュア入力・機密アプリ・除外アプリでは、選択範囲を読まず、書き込まない（7章）。
///   音声指示の送信の直前にも、選択範囲を読んだ入力欄と開始時の前面アプリで判定し直し、機密入力なら送らない（AC-12）
/// - 選択テキスト・音声指示・編集案をログに出さない
@MainActor
final class EditModeCoordinator {
  /// 進行中の Edit。選択範囲と、それを読んだ入力欄
  private struct ActiveEdit {
    var session: EditSession
    let target: InsertionTargetID
    let app: String?
    /// 選択範囲（UTF-16 単位）
    let range: FieldSnapshot.Selection
    let generation: Int
  }

  /// 確定して、元に戻せる Edit
  private struct CommittedEdit {
    var session: EditSession
    let target: InsertionTargetID
    let app: String?
    /// 確定したテキストが入っている範囲（UTF-16 単位）
    let range: FieldSnapshot.Selection
    /// 元の選択テキストが入っていた範囲の長さ（UTF-16 単位）
    let originalLength: Int
    let committedText: String
    /// 置き換える前と後の値の長さ（UTF-16 単位）。⌘Z などで戻ったかの判定に使う。値そのものは持たない
    let valueLengthBefore: Int
    let valueLengthAfter: Int
  }

  /// 置き換えの結果と、置き換える前の値の長さ（UTF-16 単位）
  private struct Replacement {
    let result: InsertionResult
    let valueLengthBefore: Int
  }

  private let inspector: any InsertionTargetInspector
  private let field: any EditFieldAccess
  private let permissions: any InsertionPermissions
  private let presenter: any EditModePresenting
  private let clock: any InsertionClock
  private let sender: any EditRequestSending
  private let sensitivePolicy: @MainActor () -> SensitiveInputPolicy
  private let timing: InsertionTiming

  private var active: ActiveEdit?
  private var committed: CommittedEdit?
  private var generation = 0
  /// 応答を待っている Edit の世代。キャンセル・やり直しの後の Edit は待たせない
  private var requestingGeneration: Int?

  /// - Parameters:
  ///   - sender: 選択テキストと音声指示の送信。同意・機密入力・予算の確認を含む
  ///   - sensitivePolicy: 機密入力の判定。利用者の除外アプリを反映するため、判定のたびに呼ぶ（7章, AC-12）
  init(
    inspector: any InsertionTargetInspector,
    field: any EditFieldAccess,
    permissions: any InsertionPermissions,
    presenter: any EditModePresenting,
    clock: any InsertionClock,
    sender: any EditRequestSending,
    sensitivePolicy: @escaping @MainActor () -> SensitiveInputPolicy = { SensitiveInputPolicy() },
    timing: InsertionTiming = InsertionTiming()
  ) {
    self.inspector = inspector
    self.field = field
    self.permissions = permissions
    self.presenter = presenter
    self.clock = clock
    self.sender = sender
    self.sensitivePolicy = sensitivePolicy
    self.timing = timing
  }

  /// `EditRouter` へ直接送る。テストと、設定を読まない組み立てに使う
  ///
  /// - Parameters:
  ///   - consent: 送信の直前に呼び、最新の同意状態を返す
  ///   - budget: 予算上限の設定（AI-04, AI-05）。未設定なら `nil`
  ///   - dictionaryTerms: 表記を保つ辞書語
  convenience init(
    inspector: any InsertionTargetInspector,
    field: any EditFieldAccess,
    permissions: any InsertionPermissions,
    presenter: any EditModePresenting,
    clock: any InsertionClock,
    router: EditRouter,
    consent: @escaping @MainActor () -> ConsentState,
    budget: @escaping @MainActor () -> RefinementBudget? = { nil },
    dictionaryTerms: @escaping @MainActor () -> [String] = { [] },
    sensitivePolicy: SensitiveInputPolicy = SensitiveInputPolicy(),
    timing: InsertionTiming = InsertionTiming()
  ) {
    self.init(
      inspector: inspector, field: field, permissions: permissions, presenter: presenter,
      clock: clock,
      sender: RouterEditSender(
        router: router, consent: consent, budget: budget, dictionaryTerms: dictionaryTerms),
      sensitivePolicy: { sensitivePolicy }, timing: timing)
  }

  /// 音声指示を受け付けている（または応答を待っている・差分を確認している）Edit があるか
  var hasActiveEdit: Bool { active != nil }

  /// 確認中の編集案（差分プレビュー）があるか
  var hasProposal: Bool {
    guard let active, case .reviewing = active.session.state else { return false }
    return true
  }

  /// 元に戻せる Edit があるか
  var canUndo: Bool { committed != nil }

  // MARK: - 開始

  /// フォーカス中の入力欄の選択テキストで Edit を始める。始められなければ通知して理由を返す。
  ///
  /// 進行中の Edit があればキャンセルし、確認中の差分プレビューを閉じる。元に戻せる Edit は手放す
  /// （元に戻せるのは直前に確定した1件だけ）。
  @discardableResult
  func begin() -> EditStartFailure? {
    discardActive()
    committed = nil
    // 読み戻しを待っている確定が、終わってから古い Edit を元に戻せる Edit として残さないようにする
    generation += 1
    if let failure = startEdit() {
      presenter.showNotice(.couldNotStart(failure))
      return failure
    }
    return nil
  }

  private func startEdit() -> EditStartFailure? {
    guard permissions.isAccessibilityTrusted() else { return .accessibilityNotTrusted }
    guard let id = inspector.recordTarget(), let focused = inspector.focusedTarget(),
      focused.id == id
    else { return .targetMissing }
    let reasons = sensitiveReasons(
      secureField: focused.secureField, app: focused.app)
    guard reasons.isEmpty else { return .sensitiveInput(reasons) }

    let snapshot = field.snapshot(of: id)
    guard let range = snapshot.selection else { return .selectionUnreadable }
    guard range.length > 0 else { return .noSelection }
    guard let value = snapshot.value, let selected = field.selectedText(of: id),
      Self.text(in: value, at: range) == selected
    else { return .selectionUnreadable }
    guard let session = try? EditSession(selection: selected) else { return .noSelection }

    active = ActiveEdit(
      session: session, target: id, app: focused.app, range: range, generation: generation)
    return nil
  }

  // MARK: - 音声指示

  /// 音声指示（STT テキスト）で編集案を求め、差分プレビューに表示する。
  ///
  /// 確認中に呼ぶと、同じ選択テキストに対する新しい音声指示として編集案を置き換える。
  /// 編集案を得られなければ通知し、選択範囲は変えない。
  @discardableResult
  func submit(instruction: String) async -> EditSubmitResult {
    guard let edit = active else { return .noActiveEdit }
    guard requestingGeneration != edit.generation else { return .busy }

    let transmission: EditSelectionTransmission
    do {
      transmission = try edit.session.cloudTransmission(
        to: sender.destination, consent: sender.currentConsent())
    } catch .transmissionNotConsented {
      return notEdited(.consentNotGranted)
    } catch {
      return .noActiveEdit
    }

    requestingGeneration = edit.generation
    defer {
      if requestingGeneration == edit.generation { requestingGeneration = nil }
    }
    let terms = await sender.dictionaryTerms()
    // 辞書を読む間にキャンセル・やり直しされていたら送らない
    guard active?.generation == edit.generation else { return .superseded }
    let request = EditRequest(transmission, instruction: instruction, dictionaryTerms: terms)
    // 送る直前に、選択範囲を読んだ入力欄と開始時の前面アプリで判定し直す（AC-12）
    let target = edit.target
    let app = edit.app
    let sensitivity: @MainActor () -> SensitiveInputDecision = { [weak self] in
      // 判定できなければ送らない（7章）
      guard let self else { return Self.undeterminedDecision }
      return sensitiveDecision(secureField: field.secureField(of: target), app: app)
    }
    let result: EditSendResult
    do {
      result = try await sender.send(request, sensitivity: sensitivity)
    } catch {
      return .superseded
    }
    // 応答を待つ間にキャンセル・やり直しされていたら、古い Edit の編集案は表示しない
    guard var current = active, current.generation == edit.generation else { return .superseded }
    let outcome: EditOutcome
    switch result {
    case .unavailable(let reason):
      presenter.showNotice(.notSent(reason))
      return .notSent(reason)
    case .outcome(let value):
      outcome = value
    }
    if let reason = outcome.failureReason {
      return notEdited(reason)
    }
    guard (try? current.session.propose(outcome)) == true,
      case .reviewing(let proposal) = current.session.state
    else { return .noActiveEdit }
    active = current
    presenter.showProposal(proposal)
    return .proposed
  }

  private func notEdited(_ reason: EditFailureReason) -> EditSubmitResult {
    presenter.showNotice(.notEdited(reason))
    return .notEdited(reason)
  }

  // MARK: - キャンセル・確定

  /// 確定せずに終える。選択範囲は変えない。応答を待っている場合は、届いた編集案を捨てる。
  func cancel() {
    discardActive()
  }

  private func discardActive() {
    guard var edit = active else { return }
    try? edit.session.cancel()
    active = nil
    presenter.dismissProposal()
  }

  /// 確認中の編集案で確定し、選択範囲を置き換える。
  @discardableResult
  func commit() async -> EditCommitResult {
    guard var edit = active, case .reviewing = edit.session.state,
      let text = try? edit.session.commit()
    else { return .noProposal }
    active = nil
    presenter.dismissProposal()

    let original = edit.session.selection
    switch await replace(
      in: edit.target, app: edit.app, range: edit.range, expected: original, with: text)
    {
    case .success(let replacement):
      let result = replacement.result
      // 読み戻しを待つ間に次の Edit が始まっていたら、元に戻せる Edit にしない
      if generation == edit.generation {
        committed = CommittedEdit(
          session: edit.session, target: edit.target, app: edit.app,
          range: FieldSnapshot.Selection(location: edit.range.location, length: text.utf16.count),
          originalLength: edit.range.length, committedText: text,
          valueLengthBefore: replacement.valueLengthBefore,
          valueLengthAfter: replacement.valueLengthBefore - edit.range.length + text.utf16.count)
      }
      presenter.showNotice(.replaced(verified: result == .verified(.accessibility)))
      return .replaced(result)
    case .failure(let cause):
      presenter.showFallback(text: text, cause: cause)
      return .fallback(cause)
    }
  }

  // MARK: - 元に戻す

  /// 直前に確定した Edit を元に戻す（Undo）。一度だけ行える。
  ///
  /// アプリの ⌘Z で戻せる入力欄では、すでに元のテキストに戻っていれば何もしない。
  @discardableResult
  func undo() async -> EditUndoResult {
    guard var edit = committed else { return .nothingToUndo }
    committed = nil
    let original = edit.session.selection

    // 書き込みの前に、該当範囲が確定したテキストのままか確かめる。戻っていれば何もしない
    // 範囲の文字列だけでは、確定テキストが元のテキストを含む場合（会議 → 会議室）や削除の場合に取り違えるため、値の長さも比べる
    if let value = field.value(of: edit.target) {
      let length = value.utf16.count
      let originalRange = FieldSnapshot.Selection(
        location: edit.range.location, length: edit.originalLength)
      if length == edit.valueLengthBefore, Self.text(in: value, at: originalRange) == original {
        presenter.showNotice(.alreadyRestored)
        return .alreadyRestored
      }
      let stillCommitted =
        Self.text(in: value, at: edit.range) == edit.committedText
        && (!edit.committedText.isEmpty || length == edit.valueLengthAfter)
      guard stillCommitted else { return undoFallback(original, cause: .changedSinceCommit) }
    }
    guard let restoration = try? edit.session.restore() else { return .nothingToUndo }

    switch await replace(
      in: edit.target, app: edit.app, range: edit.range, expected: restoration.expectedText,
      with: restoration.replacement)
    {
    case .success(let replacement):
      let result = replacement.result
      presenter.showNotice(.restored(verified: result == .verified(.accessibility)))
      return .restored(result)
    case .failure(let cause):
      return undoFallback(
        original, cause: cause == .selectionChanged ? .changedSinceCommit : cause)
    }
  }

  private func undoFallback(_ original: String, cause: EditFallbackCause) -> EditUndoResult {
    presenter.showFallback(text: original, cause: cause)
    return .fallback(cause)
  }

  // MARK: - 置き換え

  /// `range` に `expected` があることを確かめてから、その範囲を `text` に置き換えて読み戻す。
  private func replace(
    in target: InsertionTargetID, app: String?, range: FieldSnapshot.Selection,
    expected: String, with text: String
  ) async -> Result<Replacement, EditFallbackCause> {
    guard permissions.isAccessibilityTrusted() else { return .failure(.accessibilityNotTrusted) }
    let reasons = sensitiveReasons(secureField: field.secureField(of: target), app: app)
    guard reasons.isEmpty else { return .failure(.sensitiveInput(reasons)) }

    var before = field.snapshot(of: target)
    guard let value = before.value else { return .failure(.targetMissing) }
    // 確認中・確定後に利用者が書き換えていたら、その入力を上書きしない
    guard Self.text(in: value, at: range) == expected else { return .failure(.selectionChanged) }
    if before.selection != range {
      // 選択範囲が動いていれば元の範囲を選び直す。選び直せなければ、別の位置へ書き込まないよう置き換えない
      guard field.select(range, in: target) else { return .failure(.cannotReselect) }
      before = field.snapshot(of: target)
      guard before.selection == range, let value = before.value,
        Self.text(in: value, at: range) == expected
      else { return .failure(.selectionChanged) }
    }

    let response = field.insertAtSelection(text, into: target)
    let readBack =
      response == .rejectedBeforeSend
      ? .unavailable : await readBack(target: target, before: before, text: text)
    let result = InsertionResult.classify(
      route: .accessibility, response: response, readBack: readBack)
    return result.mayHaveInserted
      ? .success(
        Replacement(result: result, valueLengthBefore: (before.value ?? value).utf16.count))
      : .failure(.replacementFailed)
  }

  /// アプリが値を反映するまで待ちながら読み戻す（`InsertionExecutor` と同じ待ち方, INS-05）
  private func readBack(target: InsertionTargetID, before: FieldSnapshot, text: String) async
    -> InsertionReadBack
  {
    let deadline = clock.elapsed() + timing.readBackTimeout
    var last = ReadBackEvaluator.evaluate(
      before: before, after: field.value(of: target), text: text)
    while last != .matches, last != .unavailable, clock.elapsed() < deadline {
      if Task.isCancelled { return .unavailable }
      await clock.sleep(for: timing.readBackInterval)
      last = ReadBackEvaluator.evaluate(
        before: before, after: field.value(of: target), text: text)
    }
    return last != .matches && Task.isCancelled ? .unavailable : last
  }

  // MARK: - 判定

  private func sensitiveReasons(secureField: SensitiveSignal, app: String?)
    -> Set<SensitiveInputReason>
  {
    sensitiveDecision(secureField: secureField, app: app).reasons
  }

  private func sensitiveDecision(secureField: SensitiveSignal, app: String?)
    -> SensitiveInputDecision
  {
    let context = SensitiveInputContext(
      secureField: secureField, secureEventInput: inspector.secureEventInput(), app: app)
    return sensitivePolicy().decide(context)
  }

  /// 入力先を判定できないときの結果。送らない・書き込まない
  private static var undeterminedDecision: SensitiveInputDecision {
    SensitiveInputPolicy().decide(
      SensitiveInputContext(secureField: .unknown, secureEventInput: .unknown, app: nil))
  }

  /// `value` の `range`（UTF-16 単位）の文字列。範囲が値の外か、文字（`Character`）の境界でない位置
  /// （サロゲートペア・結合文字・`\r\n` の途中など）を指すなら `nil`
  static func text(in value: String, at range: FieldSnapshot.Selection) -> String? {
    let utf16 = value.utf16
    guard range.location >= 0, range.length >= 0, range.location <= utf16.count - range.length
    else { return nil }
    let start = utf16.index(utf16.startIndex, offsetBy: range.location)
    let end = utf16.index(start, offsetBy: range.length)
    guard let lower = start.samePosition(in: value), let upper = end.samePosition(in: value) else {
      return nil
    }
    return String(value[lower..<upper])
  }
}

/// `EditRouter` へ直接送る送信部。同意・予算・辞書語は渡されたクロージャから読む。
///
/// 設定・API キーを読まないため、本番の結線（`EditModeRequestPipeline`）ではなく、テストと実機確認の組み立てに使う。
@MainActor
final class RouterEditSender: EditRequestSending {
  private let router: EditRouter
  private let consent: @MainActor () -> ConsentState
  private let budget: @MainActor () -> RefinementBudget?
  private let terms: @MainActor () -> [String]

  init(
    router: EditRouter,
    consent: @escaping @MainActor () -> ConsentState,
    budget: @escaping @MainActor () -> RefinementBudget? = { nil },
    dictionaryTerms: @escaping @MainActor () -> [String] = { [] }
  ) {
    self.router = router
    self.consent = consent
    self.budget = budget
    terms = dictionaryTerms
  }

  var destination: CloudAIProviderKind { router.provider.destination }

  func currentConsent() -> ConsentState {
    consent()
  }

  func dictionaryTerms() async -> [String] {
    terms()
  }

  func send(
    _ request: EditRequest,
    sensitivity: @escaping @MainActor () -> SensitiveInputDecision
  ) async throws(CancellationError) -> EditSendResult {
    // `EditRouter` は同期的に同意と判定を求めるため、送る直前にここで読んだ値を渡す。Router は予約を待った後にも求めるが、
    // 同意と入力先はメインスレッドでしか読めないため、予約の間（BudgetGuard への1回の切り替え）の変化はここまでしか反映しない
    let consentState = consent()
    let decision = sensitivity()
    let outcome = try await router.edit(
      request, consent: { consentState }, budget: budget(), sensitivity: { decision })
    return .outcome(outcome)
  }
}
