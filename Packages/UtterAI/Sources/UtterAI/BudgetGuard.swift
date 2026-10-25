import Foundation

/// 予算判定と使用量の記録を排他的に行う（AI-04, AI-05）。
///
/// 送信前に見込み費用を予約し、応答後に実際の使用量で確定する。予約中の費用も判定に含めるため、
/// 並行して送信しても上限を超えて許可しない。
///
/// 台帳の永続化は呼び出し側（アプリ）が行う。UtterAI は UtterPersistence に依存しないため、記録のたびに呼ばれる
/// `onRecord` でアプリが UtterPersistence の `MonthlyUsageStore` へ加算し、
/// 起動時は保存済みの累計から `MonthlyUsageLedger(currency:spentByMonth:)` で台帳を復元して渡す。
public actor BudgetGuard {
  public let budget: MonthlyBudget
  public let estimator: CostEstimator
  public private(set) var ledger: MonthlyUsageLedger
  private var reservations: [UUID: BudgetReservation] = [:]
  private let onRecord: (@Sendable (RecordedEstimatedCost) throws -> Void)?
  /// `onRecord` が失敗した（推定費用を永続化できなかった）か。
  ///
  /// 失敗すると再起動後に累計を少なく数えうるため、以降の予約はすべて拒否する（安全側）。
  /// アプリは利用者に保存の失敗を知らせ、保存できる状態に戻してから台帳を復元し直した `BudgetGuard` を作る
  public private(set) var hasPersistenceFailure = false

  /// - Parameter onRecord: 台帳に推定費用を記録するたびに、この actor の上で同期的に呼ばれる（AI-05）。
  ///   送信後に呼び出し元がキャンセルして `RefinementRouter.refine` が結果を返さない場合も呼ばれるため、
  ///   永続化はこの経路で行う。長く待つ処理をしない。エラーを投げると `hasPersistenceFailure` になり、以降の予約を拒否する
  public init(
    budget: MonthlyBudget,
    estimator: CostEstimator,
    ledger: MonthlyUsageLedger,
    onRecord: (@Sendable (RecordedEstimatedCost) throws -> Void)? = nil
  ) {
    self.budget = budget
    self.estimator = estimator
    self.ledger = ledger
    self.onRecord = onRecord
  }

  /// 予算に収まれば見込み費用を予約して返す。収まらない・推定できない場合と、
  /// 推定費用を永続化できなかった後（`hasPersistenceFailure`）は `budgetExceeded` を投げる。
  public func reserve(
    model: String,
    expectedUsage: TokenUsage,
    in month: YearMonth
  ) throws(AIProviderError) -> BudgetReservation {
    guard !hasPersistenceFailure else {
      throw .budgetExceeded
    }
    let reserved = reservations.values.filter { $0.month == month }.reduce(Decimal(0)) {
      $0 + $1.amount
    }
    let result = budget.decide(
      model: model, expectedUsage: expectedUsage, estimator: estimator, ledger: ledger, in: month,
      reserved: reserved)
    guard result.decision == .allowed, let pending = result.pending else {
      throw .budgetExceeded
    }
    let reservation = BudgetReservation(
      id: UUID(), model: model, month: month, amount: pending.amount)
    reservations[reservation.id] = reservation
    return reservation
  }

  /// 送信後に予約を確定し、推定費用を台帳に記録する。
  ///
  /// 実際の使用量がわからない、または推定できない（数値で表せない額を含む）場合は、課金されている可能性があるため予約した見込み費用を記録する。
  /// 確定済み・取り消し済みの予約や、別の `BudgetGuard` の予約は何もしない。
  ///
  /// - Returns: 台帳に記録した推定費用と計上した月。記録しなかった場合は `nil`。記録した場合は `onRecord` にも同じ値を渡す
  @discardableResult
  public func settle(_ reservation: BudgetReservation, actualUsage: TokenUsage?)
    -> RecordedEstimatedCost?
  {
    guard release(reservation) else {
      return nil
    }
    let amount: Decimal
    if let actualUsage,
      let cost = try? estimator.estimate(model: reservation.model, usage: actualUsage),
      !cost.amount.isNaN
    {
      amount = cost.amount
    } else {
      amount = reservation.amount
    }
    // 予約時に通貨の一致を確認済みのため、記録は失敗しない。
    let cost = EstimatedCost(amount: amount, currency: ledger.currency)
    do throws(PricingError) {
      try ledger.record(cost, in: reservation.month)
    } catch {
      return nil
    }
    let recorded = RecordedEstimatedCost(cost: cost, month: reservation.month)
    do {
      try onRecord?(recorded)
    } catch {
      hasPersistenceFailure = true
    }
    return recorded
  }

  /// 指定した月の推定費用の表示用の値（AI-05）。予約中の見込み費用も含める。
  ///
  /// 予算・台帳・単価表の通貨が一致しない場合は、異なる通貨を足し引きしないよう `currencyMismatch` を投げる。
  public func estimatedCostSummary(in month: YearMonth) throws(PricingError)
    -> EstimatedCostSummary
  {
    let reserved = reservations.values.filter { $0.month == month }.reduce(Decimal(0)) {
      $0 + $1.amount
    }
    return try EstimatedCostSummary(
      month: month, budget: budget, ledger: ledger, reserved: reserved,
      priceTable: estimator.priceTable)
  }

  /// 送信しなかった場合に予約を取り消す。台帳には記録しない。
  public func cancel(_ reservation: BudgetReservation) {
    release(reservation)
  }

  /// この `BudgetGuard` が発行した未解放の予約なら解放して `true` を返す。
  @discardableResult
  private func release(_ reservation: BudgetReservation) -> Bool {
    guard reservations[reservation.id] == reservation else {
      return false
    }
    reservations[reservation.id] = nil
    return true
  }
}

extension BudgetGuard {
  /// 送信の結果に応じて予約を確定または取り消す（AI-05）。
  ///
  /// 応答があれば実際の使用量で確定する。課金されない失敗（`AIProviderError.isUnbilled`）は取り消し、
  /// それ以外の失敗は課金されている可能性があるため見込み費用で確定する。
  /// 整形（`RefinementRouter`）とクラウド STT（`OpenAISpeechRecognizer`）で共通に使う。
  ///
  /// - Returns: 台帳に記録した推定費用。取り消した場合は `nil`
  @discardableResult
  func resolve(
    _ reservation: BudgetReservation,
    with result: Result<TokenUsage?, AIProviderError>
  ) -> RecordedEstimatedCost? {
    switch result {
    case .success(let usage):
      return settle(reservation, actualUsage: usage)
    case .failure(let error) where error.isUnbilled:
      cancel(reservation)
      return nil
    case .failure:
      return settle(reservation, actualUsage: nil)
    }
  }
}

/// 送信前に予約した見込み費用（AI-05）。`BudgetGuard.settle` か `cancel` で必ず解放する。
public struct BudgetReservation: Hashable, Sendable {
  let id: UUID
  public let model: String
  public let month: YearMonth
  /// 予約した見込みの推定費用
  public let amount: Decimal
}

/// `BudgetGuard.settle` が台帳に記録した推定費用と、計上した月（AI-05）。
///
/// トークン使用量と利用者の単価表から計算した**推定値**で、プロバイダーの請求額ではない。
public struct RecordedEstimatedCost: Hashable, Sendable {
  public let cost: EstimatedCost
  public let month: YearMonth

  public init(cost: EstimatedCost, month: YearMonth) {
    self.cost = cost
    self.month = month
  }
}
