import Foundation

/// 月ごとの予算上限（AI-04, AI-05）。
public struct MonthlyBudget: Hashable, Sendable {
  public let limit: EstimatedCost

  public init(limit: EstimatedCost) throws(PricingError) {
    guard limit.amount >= 0 else {
      throw .negativeAmount
    }
    self.limit = limit
  }

  /// 送信前に予算を判定する。今月の推定費用が上限に達していれば `budgetExceeded` を投げる。
  ///
  /// 通貨が一致しない場合は予算を評価できないため、安全側に倒して `budgetExceeded` とする。
  public func ensureCanSend(ledger: MonthlyUsageLedger, in month: YearMonth) throws(AIProviderError)
  {
    guard ledger.currency == limit.currency else {
      throw .budgetExceeded
    }
    guard ledger.spent(in: month) < limit.amount else {
      throw .budgetExceeded
    }
  }
}
