import UtterCore

/// Edit Mode の選択テキストと音声指示を、選択されたクラウドプロバイダーへ1回だけ送信し、応答を検証して返す（AC-14, 2.2節）。
///
/// 送信には、音声入力の整形（`textRefinement`）とは別の、送信先ごとの選択テキストの送信（`editSelection`）への
/// 同意が要る（AC-06, 7章）。送信しないローカルでは音声指示による編集ができないため、同意がない・機密入力・失敗・
/// 上限時間の超過・検証失敗のときは、ローカル整形で代わりの結果を作らず「編集できなかった」結果を返す。
/// 失敗しても再送や別のクラウドプロバイダーへの切り替えはしない（AI-04）。
public struct EditRouter: Sendable {
  public let provider: any AIEditProvider
  public let validator: EditValidator
  /// 応答待ちの上限時間
  public let timeout: Duration

  public init(
    provider: any AIEditProvider,
    validator: EditValidator = EditValidator(),
    timeout: Duration = RefinementRouter.defaultTimeout
  ) throws(RefinementRouterError) {
    guard timeout > .zero else {
      throw .nonPositiveTimeout
    }
    self.provider = provider
    self.validator = validator
    self.timeout = timeout
  }

  /// 選択テキストを音声指示に従って書き換えた編集案を求める。
  ///
  /// 呼び出し元はキャンセルしていないのにプロバイダーが `.cancelled` を返した場合は、他の失敗と同じく
  /// 編集できなかった結果を返す。
  ///
  /// - Parameters:
  ///   - consent: 最新の同意状態を返す。プロバイダーの送信先への選択テキストの送信の同意がなければ、
  ///     プロバイダーを呼ばない（AC-06）。`request` を作ったときの送信先がプロバイダーの送信先と違う場合も、
  ///     別の送信先への同意で送らないよう、呼ばずに `.destinationMismatch` を返す。
  ///     整形・音声・別の送信先への同意では送信しない。扱いは `RefinementRouter.refine(_:consent:budget:sensitivity:)`
  ///     と同じで、予約の前と、予約を待った後のプロバイダーを呼ぶ直前に呼ぶ。予約を待つ間に撤回された場合は、
  ///     送信せずに予約を取り消す。同期的に呼ぶため、メインスレッドを待たずに返す（最新の同意状態を保持しておき、それを返すなど）
  ///   - budget: 予算上限の設定（AI-04, AI-05）。扱いは `RefinementRouter.refine(_:consent:budget:sensitivity:)` と同じで、
  ///     上限を超えるならプロバイダーを呼ばずに `.providerFailed(.budgetExceeded)` を返す
  ///   - sensitivity: その時点の入力先（選択範囲のある入力先）で判定し直した結果（7章, AC-12）。
  ///     `allowsCloudTransmission` でなければプロバイダーを呼ばずに `.sensitiveInputSuppressed` を返す。
  ///     扱いは `RefinementRouter.refine(_:consent:budget:sensitivity:)` と同じで、予約の前と、予約を待った後の
  ///     プロバイダーを呼ぶ直前に呼ぶ。予約を待つ間に機密入力へ変わった場合は、送信せずに予約を取り消す。
  ///     確認を省略できないよう既定値は持たせない。同期的に呼ぶため、メインスレッドを待たずに返す
  ///     （入力先の最新の判定を保持しておき、それを返すなど）
  /// - Throws: 呼び出し元の Task がキャンセルされた場合
  public func edit(
    _ request: EditRequest,
    consent: @Sendable () -> ConsentState,
    budget: RefinementBudget?,
    sensitivity: @Sendable () -> SensitiveInputDecision
  ) async throws(CancellationError) -> EditOutcome {
    if Task.isCancelled {
      throw CancellationError()
    }
    if request.instruction.allSatisfy(\.isWhitespace) {
      return EditOutcome(content: .notEdited(.emptyInstruction))
    }
    guard request.destination == provider.destination else {
      return EditOutcome(content: .notEdited(.destinationMismatch))
    }
    guard consent().allows(.editSelection(provider.destination)) else {
      return EditOutcome(content: .notEdited(.consentNotGranted))
    }
    // 機密入力なら予約もしない
    guard sensitivity().allowsCloudTransmission else {
      return EditOutcome(content: .notEdited(.sensitiveInputSuppressed))
    }

    let reservation: BudgetReservation?
    switch try await RefinementRouter.reserve(budget) {
    case .success(let reserved):
      reservation = reserved
    case .failure(let error):
      return EditOutcome(content: .notEdited(.providerFailed(error)))
    }
    // 予約を待つ間に同意が撤回されたら、送信せずに予約を取り消す
    if let budget, let reservation, !consent().allows(.editSelection(provider.destination)) {
      await budget.guard.cancel(reservation)
      return EditOutcome(content: .notEdited(.consentNotGranted))
    }
    // 予約を待つ間に入力先が機密入力へ変わったら、送信せずに予約を取り消す
    if let budget, let reservation, !sensitivity().allowsCloudTransmission {
      await budget.guard.cancel(reservation)
      return EditOutcome(content: .notEdited(.sensitiveInputSuppressed))
    }

    let provider = provider
    let result = await RefinementRouter.requestWithTimeout(timeout) {
      () async -> RefinementResult in
      do throws(AIProviderError) {
        return .success(try await provider.edit(request))
      } catch {
        return .failure(error)
      }
    }
    if let budget, let reservation {
      await budget.guard.resolve(reservation, with: result.map(\.usage))
    }
    if Task.isCancelled {
      throw CancellationError()
    }

    switch result {
    case .success(let response):
      if let failure = validator.validate(response.text, for: request) {
        return EditOutcome(content: .notEdited(.validationFailed(failure)), usage: response.usage)
      }
      return EditOutcome(
        content: .proposal(Self.keepingSurroundingNewlines(of: request.selection, response.text)),
        usage: response.usage)
    case .failure(let error):
      return EditOutcome(content: .notEdited(.providerFailed(error)))
    }
  }

  /// 応答の前後の改行を除き、選択テキストの前後にあった改行を付け直す。
  ///
  /// 応答の末尾に付きがちな改行で選択範囲の外の行を崩さず、選択範囲の前後の改行も失わないようにする。
  /// 行頭のスペース・タブはインデントの編集を壊さないよう、そのまま残す。
  static func keepingSurroundingNewlines(of selection: String, _ edited: String) -> String {
    let leading = selection.prefix(while: \.isNewline)
    // 選択テキストが改行だけなら、前後の改行は同じ文字列を指すため二重に付けない
    let trailing =
      leading.count < selection.count
      ? String(selection.reversed().prefix(while: \.isNewline).reversed()) : ""
    return String(leading) + trimmingNewlines(edited) + trailing
  }

  /// 前後の改行だけを除く。
  static func trimmingNewlines(_ text: String) -> String {
    String(text.drop(while: \.isNewline).reversed().drop(while: \.isNewline).reversed())
  }
}
