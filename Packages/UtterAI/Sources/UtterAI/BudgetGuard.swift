import Foundation

/// 予算判定と使用量の記録を排他的に行う（AI-04, AI-05）。
///
/// 送信前に見込み費用を予約し、応答後に実際の使用量で確定する。予約中の費用も判定に含めるため、
/// 並行して送信しても上限を超えて許可しない。台帳の永続化は呼び出し側（UtterPersistence）が `ledger` を保存して行う。
public actor BudgetGuard {
  public let budget: MonthlyBudget
  public let estimator: CostEstimator
  public private(set) var ledger: MonthlyUsageLedger
  private var reservations: [UUID: BudgetReservation] = [:]

  public init(budget: MonthlyBudget, estimator: CostEstimator, ledger: MonthlyUsageLedger) {
    self.budget = budget
    self.estimator = estimator
    self.ledger = ledger
  }

  /// 予算に収まれば見込み費用を予約して返す。収まらない・推定できない場合は `budgetExceeded` を投げる。
  public func reserve(
    model: String,
    expectedUsage: TokenUsage,
    in month: YearMonth
  ) throws(AIProviderError) -> BudgetReservation {
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
  /// 実際の使用量がわからない、または推定できない場合は、課金されている可能性があるため予約した見込み費用を記録する。
  /// 確定済み・取り消し済みの予約や、別の `BudgetGuard` の予約は何もしない。
  public func settle(_ reservation: BudgetReservation, actualUsage: TokenUsage?) {
    guard release(reservation) else {
      return
    }
    let amount: Decimal
    if let actualUsage,
      let cost = try? estimator.estimate(model: reservation.model, usage: actualUsage)
    {
      amount = cost.amount
    } else {
      amount = reservation.amount
    }
    // 予約時に通貨の一致を確認済みのため、記録は失敗しない。
    try? ledger.record(
      EstimatedCost(amount: amount, currency: ledger.currency), in: reservation.month)
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
  /// 応答があれば実際の使用量で確定する。認証や利用枠で拒否された場合は課金されないため取り消す。
  /// 上限時間の超過・応答の解釈失敗・キャンセルと、ネットワークの失敗は、課金されている可能性があるため見込み費用で確定する。
  /// ネットワークの失敗には応答の途中で切れた場合も含まれ、送信前の失敗と区別できないため、多めに数える側に倒す。
  /// 整形（`RefinementRouter`）とクラウド STT（`OpenAISpeechRecognizer`）で共通に使う。
  func resolve(
    _ reservation: BudgetReservation,
    with result: Result<TokenUsage?, AIProviderError>
  ) {
    switch result {
    case .success(let usage):
      settle(reservation, actualUsage: usage)
    case .failure(.authenticationExpired), .failure(.quotaExceeded), .failure(.budgetExceeded):
      cancel(reservation)
    case .failure(.timeout), .failure(.invalidResponse), .failure(.cancelled),
      .failure(.networkUnavailable):
      settle(reservation, actualUsage: nil)
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
