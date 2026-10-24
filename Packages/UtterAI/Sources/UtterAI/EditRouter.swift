import UtterCore

/// Edit Mode の選択テキストと音声指示を、選択されたクラウドプロバイダーへ1回だけ送信し、応答を検証して返す（AC-14, 2.2節）。
///
/// 送信には、音声入力の整形（`textRefinement`）とは別の、送信先ごとの選択テキストの送信（`editSelection`）への
/// 同意が要る（AC-06, 7章）。送信しないローカルでは音声指示による編集ができないため、同意がない・失敗・
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
  ///   - consent: `edit` を呼んだ時点の最新の同意状態。プロバイダーの送信先への選択テキストの送信の同意がなければ、
  ///     プロバイダーを呼ばない（AC-06）。`request` を作ったときの送信先がプロバイダーの送信先と違う場合も、
  ///     別の送信先への同意で送らないよう、呼ばずに `.destinationMismatch` を返す。
  ///     整形・音声・別の送信先への同意では送信しない
  ///   - budget: 予算上限の設定（AI-04, AI-05）。扱いは `RefinementRouter.refine(_:consent:budget:)` と同じで、
  ///     上限を超えるならプロバイダーを呼ばずに `.providerFailed(.budgetExceeded)` を返す
  /// - Throws: 呼び出し元の Task がキャンセルされた場合
  public func edit(
    _ request: EditRequest,
    consent: ConsentState,
    budget: RefinementBudget?
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
    guard consent.allows(.editSelection(provider.destination)) else {
      return EditOutcome(content: .notEdited(.consentNotGranted))
    }

    let reservation: BudgetReservation?
    switch try await RefinementRouter.reserve(budget) {
    case .success(let reserved):
      reservation = reserved
    case .failure(let error):
      return EditOutcome(content: .notEdited(.providerFailed(error)))
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
      await RefinementRouter.resolve(reservation, with: result, in: budget.guard)
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
