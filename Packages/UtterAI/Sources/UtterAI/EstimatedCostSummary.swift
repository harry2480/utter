import Foundation

/// 推定費用の表示用の値（AI-04, AI-05）。画面は Apps が作る。
///
/// すべてトークン使用量と利用者の単価表から計算した**推定値**で、プロバイダーの請求額や
/// API クレジット残高ではない。`remaining` も予算上限に対する推定の残りで、クレジットの残りではない。
public struct EstimatedCostSummary: Hashable, Sendable {
  public let month: YearMonth
  public let currency: CostCurrency
  /// 今月の推定費用の累計（確定済み）
  public let estimatedSpent: Decimal
  /// 送信中でまだ確定していない見込みの推定費用
  public let reserved: Decimal
  /// 利用者が設定した月次予算の上限
  public let limitAmount: Decimal
  /// 推定費用の計算に使った単価表の更新日
  public let priceTableUpdatedOn: CivilDate

  /// 予算・台帳・単価表の通貨が一致しない場合は `currencyMismatch` を投げる。予約中の額が負・非数なら `negativeAmount` / `invalidAmount`
  public init(
    month: YearMonth,
    budget: MonthlyBudget,
    ledger: MonthlyUsageLedger,
    reserved: Decimal = 0,
    priceTable: PriceTable
  ) throws(PricingError) {
    guard ledger.currency == budget.currency, priceTable.currency == budget.currency else {
      throw .currencyMismatch
    }
    guard !reserved.isNaN else {
      throw .invalidAmount
    }
    guard reserved >= 0 else {
      throw .negativeAmount
    }
    self.month = month
    self.currency = budget.currency
    self.estimatedSpent = ledger.spent(in: month)
    self.reserved = reserved
    self.limitAmount = budget.limitAmount
    self.priceTableUpdatedOn = priceTable.updatedOn
  }

  /// 上限から推定累計と予約中の額を引いた推定の残り。上限を超えていても負にせず 0 にする
  public var estimatedRemaining: Decimal {
    max(0, limitAmount - estimatedSpent - reserved)
  }
}
