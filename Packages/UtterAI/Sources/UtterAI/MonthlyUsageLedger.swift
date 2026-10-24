import Foundation

/// 月ごとの推定費用の累計（AI-05）。
///
/// 永続化は UtterPersistence の `MonthlyUsageStore` が行う。UtterAI は UtterPersistence に依存しないため、
/// 保存と復元の橋渡しはアプリが行う（`init(currency:spentByMonth:)` と `BudgetGuard.settle` の戻り値）。
public struct MonthlyUsageLedger: Hashable, Sendable {
  public let currency: CostCurrency
  private var spentByMonth: [YearMonth: Decimal] = [:]

  public init(currency: CostCurrency) {
    self.currency = currency
  }

  /// 保存済みの月ごとの累計から台帳を復元する。
  ///
  /// 累計はこの台帳と同じ通貨のものだけを渡す（通貨ごとに別の台帳になり、為替換算はしない）。
  /// 負の累計は `negativeAmount`、数値でない累計は `invalidAmount` を投げ、一部だけを復元しない。
  public init(currency: CostCurrency, spentByMonth: [YearMonth: Decimal]) throws(PricingError) {
    for amount in spentByMonth.values {
      guard !amount.isNaN else {
        throw .invalidAmount
      }
      guard amount >= 0 else {
        throw .negativeAmount
      }
    }
    self.currency = currency
    self.spentByMonth = spentByMonth
  }

  /// 指定した月の推定費用の累計。記録がなければ 0。
  public func spent(in month: YearMonth) -> Decimal {
    spentByMonth[month] ?? 0
  }

  /// 推定費用を指定した月に加算する。通貨が台帳と異なる場合、負・非数の額、加算後の累計が数値でなくなる場合は記録しない。
  public mutating func record(_ cost: EstimatedCost, in month: YearMonth) throws(PricingError) {
    guard cost.currency == currency else {
      throw .currencyMismatch
    }
    guard !cost.amount.isNaN else {
      throw .invalidAmount
    }
    guard cost.amount >= 0 else {
      throw .negativeAmount
    }
    let total = spent(in: month) + cost.amount
    guard !total.isNaN else {
      throw .invalidAmount
    }
    spentByMonth[month] = total
  }
}
