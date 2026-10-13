import Foundation

/// 月ごとの推定費用の累計（AI-05）。使用量の永続化（GRDB）は別 Issue で扱う。
public struct MonthlyUsageLedger: Hashable, Sendable {
  public let currency: CostCurrency
  private var spentByMonth: [YearMonth: Decimal] = [:]

  public init(currency: CostCurrency) {
    self.currency = currency
  }

  /// 指定した月の推定費用の累計。記録がなければ 0。
  public func spent(in month: YearMonth) -> Decimal {
    spentByMonth[month] ?? 0
  }

  /// 推定費用を指定した月に加算する。通貨が台帳と異なる場合は記録しない。
  public mutating func record(_ cost: EstimatedCost, in month: YearMonth) throws(PricingError) {
    guard cost.currency == currency else {
      throw .currencyMismatch
    }
    spentByMonth[month, default: 0] += cost.amount
  }
}
