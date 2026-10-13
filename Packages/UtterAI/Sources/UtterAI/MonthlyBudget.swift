import Foundation

/// 月ごとの予算上限（AI-04, AI-05）。上限は利用者が設定する値で、推定費用と同じ通貨で比べる。
public struct MonthlyBudget: Hashable, Sendable {
  public let limitAmount: Decimal
  public let currency: CostCurrency

  public init(limitAmount: Decimal, currency: CostCurrency) throws(PricingError) {
    guard limitAmount >= 0 else {
      throw .negativeAmount
    }
    self.limitAmount = limitAmount
    self.currency = currency
  }

  /// 送信前に、今月の累計と今回の送信の見込み費用が上限に収まるかを判定する。
  ///
  /// 費用を推定できない送信（単価表にないモデル、通貨の不一致）は予算を守れないため、許可しない。
  /// 判定と記録は別の呼び出しなので、並行して送信すると上限をその件数分超えうる。
  /// 並行送信がありうる場合は、予約と記録をまとめて行う `BudgetGuard` を使う。
  ///
  /// - Parameter expectedUsage: 今回の送信の見込みのトークン使用量（入力の見込みと出力の上限など）
  public func check(
    model: String,
    expectedUsage: TokenUsage,
    estimator: CostEstimator,
    ledger: MonthlyUsageLedger,
    in month: YearMonth
  ) -> BudgetDecision {
    decide(
      model: model, expectedUsage: expectedUsage, estimator: estimator, ledger: ledger, in: month,
      reserved: 0
    ).decision
  }

  /// `reserved` は送信中でまだ記録されていない見込み費用の合計。許可した場合は今回の見込み費用も返す。
  func decide(
    model: String,
    expectedUsage: TokenUsage,
    estimator: CostEstimator,
    ledger: MonthlyUsageLedger,
    in month: YearMonth,
    reserved: Decimal
  ) -> (decision: BudgetDecision, pending: EstimatedCost?) {
    guard ledger.currency == currency, estimator.priceTable.currency == currency else {
      return (.cannotEstimate(.currencyMismatch), nil)
    }
    let pending: EstimatedCost
    do throws(CostEstimationError) {
      pending = try estimator.estimate(model: model, usage: expectedUsage)
    } catch {
      return (.cannotEstimate(.estimationFailed(error)), nil)
    }
    let spent = ledger.spent(in: month) + reserved
    guard spent < limitAmount, spent + pending.amount <= limitAmount else {
      return (.exceeded, nil)
    }
    return (.allowed, pending)
  }

  /// `check` が許可しなければ `budgetExceeded` を投げる。理由を区別したい場合は `check` を使う。
  public func ensureCanSend(
    model: String,
    expectedUsage: TokenUsage,
    estimator: CostEstimator,
    ledger: MonthlyUsageLedger,
    in month: YearMonth
  ) throws(AIProviderError) {
    let decision = check(
      model: model, expectedUsage: expectedUsage, estimator: estimator, ledger: ledger, in: month)
    guard decision == .allowed else {
      throw .budgetExceeded
    }
  }
}

/// 送信前の予算判定の結果（AI-04, AI-05）。
public enum BudgetDecision: Hashable, Sendable {
  case allowed
  /// 今月の累計、または累計と今回の見込み費用の合計が上限を超える
  case exceeded
  /// 費用を推定できないため予算を守れない
  case cannotEstimate(Reason)

  public enum Reason: Hashable, Sendable {
    /// 予算・台帳・単価表の通貨が一致しない
    case currencyMismatch
    case estimationFailed(CostEstimationError)
  }
}
