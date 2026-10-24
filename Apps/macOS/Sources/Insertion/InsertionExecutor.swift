import UtterCore

/// 自動挿入せず、コピー可能なプレビューへ退避した理由（INS-01〜03, AC-09）。
enum InsertionPreviewCause: Hashable, Sendable {
  /// 挿入の計画による退避（入力対象の消失・変更、経路の失敗、ターミナルへの改行など）
  case plan(InsertionPreviewReason)
  /// パスワード欄・セキュア入力・機密アプリ・除外アプリ、または判定できない（7章, AC-12）
  case sensitiveInput(Set<SensitiveInputReason>)
  /// Accessibility が未許可で、入力対象を確かめられない（PERM-02）。どの経路も使わない
  case accessibilityNotTrusted
  /// 前の挿入の途中に次の挿入を頼まれた。クリップボードの退避・復元が重ならないよう、後の方を退避する
  case insertionInProgress
  /// 挿入のタスクが取り消された。次の経路は試さず、文字列を失わないよう退避する
  case cancelled
}

/// 1回の挿入の結末。
enum InsertionOutcome: Hashable, Sendable {
  /// 挿入した可能性がある（確認済み・成功不明）。成功不明でも再試行しない（INS-03, INS-05）
  case finished(InsertionResult)
  /// 自動挿入せず、プレビューを表示した
  case preview(InsertionPreviewCause)
  /// 末尾の空白・改行を除くと空のため、何もしなかった
  case nothingToInsert
}

/// 挿入の報告。HUD の表示や実機確認に使う。文字列の中身は含めない。
struct InsertionReport: Hashable, Sendable {
  let outcome: InsertionOutcome
  /// 試した経路の結果（試した順）
  let attempts: [InsertionResult]
  /// Pasteboard 経路を使ったときのクリップボード復元の結果
  let clipboardRestore: ClipboardRestoreOutcome?
}

/// 挿入の待ち時間。既定値は AXInsertionProbe の既定値と同じで、Phase 0（#41）の実機結果で見直す。
struct InsertionTiming: Hashable, Sendable {
  /// 読み戻しで一致を待つ最大時間（AX の問い合わせにかかった時間を含む実時間）
  var readBackTimeout: Duration = .milliseconds(1500)
  /// 読み戻しの間隔
  var readBackInterval: Duration = .milliseconds(50)
  /// Pasteboard 経路で、読み戻しの後クリップボードを復元するまで待つ時間
  var clipboardRestoreDelay: Duration = .milliseconds(300)
}

/// 挿入の計画（`InsertionPlan`）を、AX / Pasteboard / CGEvent の経路で実行する（INS-01〜07, AC-08, AC-09）。
///
/// - 経路を試す直前ごと、および Cmd+V・キー入力を送る直前に、フォーカス中の入力対象が録音開始時と同じで、
///   パスワード欄・セキュア入力・機密アプリでないことを確かめる。違えば送らずにプレビューへ退避する（INS-01, AC-09, 7章）
/// - Accessibility が未許可なら入力対象を確かめられないため、どの経路も使わずに退避する。イベント送信が未許可なら
///   Pasteboard / CGEvent 経路を使わない（PERM-01, PERM-02）
/// - 成功不明（読み戻せない・一部だけ変わった・取り消された）なら再試行しない。読み戻しで変化がないと確かめた場合だけ
///   次の経路を試す（INS-05）
/// - Return キーを送らない。ターミナル系のアプリへの改行を含む文字列は退避し、CGEvent 経路では改行・Tab などの
///   制御文字を含む文字列を送らない（INS-03, AC-08）
/// - Pasteboard 経路は一時データの印を付けて書き込み、他のアプリが書き換えていなければ元に戻す（INS-04, INS-06）
@MainActor
final class InsertionExecutor {
  private let inspector: any InsertionTargetInspector
  private let field: any InsertionFieldAccess
  private let pasteboard: any InsertionPasteboard
  private let keyEvents: any InsertionKeyEvents
  private let permissions: any InsertionPermissions
  private let preview: any InsertionPreviewPresenting
  private let clock: any InsertionClock
  private let policy: InsertionPolicy
  private let sensitivePolicy: SensitiveInputPolicy
  private let timing: InsertionTiming
  private var isInserting = false

  init(
    inspector: any InsertionTargetInspector,
    field: any InsertionFieldAccess,
    pasteboard: any InsertionPasteboard,
    keyEvents: any InsertionKeyEvents,
    permissions: any InsertionPermissions,
    preview: any InsertionPreviewPresenting,
    clock: any InsertionClock,
    policy: InsertionPolicy = InsertionPolicy(),
    sensitivePolicy: SensitiveInputPolicy = SensitiveInputPolicy(),
    timing: InsertionTiming = InsertionTiming()
  ) {
    self.inspector = inspector
    self.field = field
    self.pasteboard = pasteboard
    self.keyEvents = keyEvents
    self.permissions = permissions
    self.preview = preview
    self.clock = clock
    self.policy = policy
    self.sensitivePolicy = sensitivePolicy
    self.timing = timing
  }

  /// 権限があり使える経路（PERM-01, PERM-02）。
  ///
  /// Pasteboard 経路は Cmd+V を、CGEvent 経路はキー入力をイベントとして送るため、イベント送信の許可が要る。
  func permittedRoutes() -> Set<InsertionRoute> {
    var routes: Set<InsertionRoute> = []
    if permissions.isAccessibilityTrusted() {
      routes.insert(.accessibility)
    }
    if permissions.canPostEvents() {
      routes.formUnion([.pasteboard, .keyEvents])
    }
    return routes
  }

  /// CGEvent 経路で送ってよい文字列か。改行・Tab などの制御文字は、送信やフォーカスの移動になりうるため送らない（INS-03）
  static func isSafeForKeyEvents(_ text: String) -> Bool {
    !text.contains(where: \.isNewline)
      && !text.unicodeScalars.contains { $0.properties.generalCategory == .control }
  }

  /// 文字列を挿入する。自動挿入できなければプレビューを表示する。
  ///
  /// - Parameters:
  ///   - text: 挿入する文字列
  ///   - recordedTarget: 録音開始時に `InsertionTargetInspector.recordTarget()` で記録した入力対象
  func insert(_ text: String, recordedTarget: InsertionTargetID?) async -> InsertionReport {
    guard !isInserting else {
      return showPreview(text, cause: .insertionInProgress, attempts: [], clipboard: nil)
    }
    isInserting = true
    defer { isInserting = false }

    // 入力対象の確認は AX で行う。未許可なら、イベントを送る経路でも送り先を確かめられない
    guard permissions.isAccessibilityTrusted() else {
      return showPreview(text, cause: .accessibilityNotTrusted, attempts: [], clipboard: nil)
    }
    let initial = inspector.focusedTarget()
    let plan = policy.plan(
      app: initial?.app, verification: .compare(recorded: recordedTarget),
      permittedRoutes: permittedRoutes())
    guard let prepared = plan.preparedText(text) else {
      return showPreview(text, cause: .plan(.multilineInTerminal), attempts: [], clipboard: nil)
    }
    guard !prepared.isEmpty else {
      return InsertionReport(outcome: .nothingToInsert, attempts: [], clipboardRestore: nil)
    }

    var attempts: [InsertionResult] = []
    var clipboard: ClipboardRestoreOutcome?
    var current = initial
    while true {
      switch plan.nextStep(after: attempts, currentTarget: current?.id) {
      case .finish(let result):
        return InsertionReport(
          outcome: .finished(result), attempts: attempts, clipboardRestore: clipboard)
      case .showPreview(let reason):
        return showPreview(text, cause: .plan(reason), attempts: attempts, clipboard: clipboard)
      case .tryRoute(let route):
        guard !Task.isCancelled else {
          return showPreview(text, cause: .cancelled, attempts: attempts, clipboard: clipboard)
        }
        let reasons = sensitiveReasons(current)
        guard reasons.isEmpty, let target = current?.id else {
          return showPreview(
            text, cause: .sensitiveInput(reasons), attempts: attempts, clipboard: clipboard)
        }
        let (result, restore) = await attempt(route, text: prepared, target: target)
        attempts.append(result)
        clipboard = restore ?? clipboard
      }
      current = inspector.focusedTarget()
    }
  }

  // MARK: - 判定

  private func sensitiveReasons(_ target: FocusedInsertionTarget?) -> Set<SensitiveInputReason> {
    let context = SensitiveInputContext(
      secureField: target?.secureField ?? .unknown,
      secureEventInput: inspector.secureEventInput(),
      app: target?.app)
    return sensitivePolicy.decide(context).reasons
  }

  /// 今のフォーカス中の入力対象が `target` のままで、機密入力でないか。イベントを送る直前に確かめる（INS-01）
  private func isStillTargeting(_ target: InsertionTargetID) -> Bool {
    guard let current = inspector.focusedTarget(), current.id == target else { return false }
    return sensitiveReasons(current).isEmpty
  }

  private func showPreview(
    _ text: String, cause: InsertionPreviewCause, attempts: [InsertionResult],
    clipboard: ClipboardRestoreOutcome?
  ) -> InsertionReport {
    preview.showPreview(text: text, cause: cause)
    return InsertionReport(
      outcome: .preview(cause), attempts: attempts, clipboardRestore: clipboard)
  }

  // MARK: - 経路

  private func attempt(_ route: InsertionRoute, text: String, target: InsertionTargetID) async
    -> (InsertionResult, ClipboardRestoreOutcome?)
  {
    let rejected = InsertionResult.classify(
      route: route, response: .rejectedBeforeSend, readBack: .unavailable)
    switch route {
    case .accessibility:
      // 記録した要素へ直接書き込むため、フォーカスの移動の影響を受けない
      let before = field.snapshot(of: target)
      let response = field.insertAtSelection(text, into: target)
      return (await classify(route, response, target: target, before: before, text: text), nil)
    case .keyEvents:
      guard Self.isSafeForKeyEvents(text) else { return (rejected, nil) }
      let before = field.snapshot(of: target)
      let response = await keyEvents.type(text, while: { isStillTargeting(target) })
      return (await classify(route, response, target: target, before: before, text: text), nil)
    case .pasteboard:
      return await pasteViaClipboard(text, target: target)
    case .textDocumentProxy:
      // iOS キーボードの経路。macOS の計画には含まれない
      return (rejected, nil)
    }
  }

  /// クリップボードを退避 → 文字列と印を書き込み → 送り先を確かめて Cmd+V → 読み戻し → 復元（INS-04, INS-06）
  private func pasteViaClipboard(_ text: String, target: InsertionTargetID) async
    -> (InsertionResult, ClipboardRestoreOutcome?)
  {
    let rejected = InsertionResult.classify(
      route: .pasteboard, response: .rejectedBeforeSend, readBack: .unavailable)
    let changeCountBeforeCapture = pasteboard.changeCount
    let snapshot = pasteboard.capture()
    // 退避の途中で書き換えられていたら、退避した内容は最新ではない。上書きせずに中止する
    guard pasteboard.changeCount == changeCountBeforeCapture else { return (rejected, nil) }
    let before = field.snapshot(of: target)
    let wrote = pasteboard.write(text, markers: ClipboardMarker.all)
    let pending = PendingClipboardRestore(
      snapshot: snapshot,
      policy: ClipboardRestorePolicy(changeCountAfterWrite: pasteboard.changeCount))
    // 退避（遅延提供のデータの読み出し）や AX の問い合わせの間にフォーカスが移っていたら送らない
    guard wrote, isStillTargeting(target), keyEvents.sendPaste() else {
      return (rejected, pending.restore(on: pasteboard))
    }
    let readBack = await readBack(target: target, before: before, text: text)
    // 読み戻せないアプリでは貼り付けの処理を確かめられない。アプリが貼り付ける前に元の内容へ戻さないよう、
    // 読み戻せるアプリの時間切れと同じだけ待ってから復元する（AXInsertionProbe と同じ待ち方）
    if readBack == .unavailable {
      await clock.sleep(for: timing.readBackTimeout)
    }
    await clock.sleep(for: timing.clipboardRestoreDelay)
    let restore = pending.restore(on: pasteboard)
    return (.classify(route: .pasteboard, response: .succeeded, readBack: readBack), restore)
  }

  private func classify(
    _ route: InsertionRoute, _ response: InsertionResponse, target: InsertionTargetID,
    before: FieldSnapshot, text: String
  ) async -> InsertionResult {
    // 送信前の失敗は何も送っていないため、読み戻さない
    let readBack =
      response == .rejectedBeforeSend
      ? .unavailable : await readBack(target: target, before: before, text: text)
    return .classify(route: route, response: response, readBack: readBack)
  }

  /// アプリが値を反映するまで待ちながら読み戻す。一致したらすぐ返し、時間切れなら最後の判定を返す（INS-05）。
  ///
  /// 時間切れは AX の問い合わせにかかった時間を含む実時間で判定する。取り消されたら、変化がないことを
  /// 確かめきれていないため読み戻せない扱いにする（成功不明として次の経路を試さない）。
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
}
