import Foundation
import UtterAI
import UtterPersistence

/// 保存した予算・単価表・推定費用の累計（UtterPersistence）を、UtterAI の費用制御の型へつなぐ（AI-04, AI-05）。
///
/// UtterAI と UtterPersistence は互いに依存しないため、橋渡しはアプリが行う。
/// 設定画面の推定費用の表示と、整形の送信前の予算判定（`BudgetGuard`）は、同じ変換を使う。
/// 変換できない設定（予算・通貨・更新日が未設定など）は `nil` にし、0 円や仮の値で補わない。
enum CloudCostBridge {
  /// 予算の判定・表示に使う値がそろわない理由
  enum Unavailable: Error, Hashable, Sendable {
    /// 月次予算が未設定
    case budgetNotSet
    /// 単価表の通貨か更新日が未設定
    case priceTableIncomplete
    /// 予算と単価表の通貨が異なる（為替換算はしない）
    case currencyMismatch
    /// 年月を集計に使える範囲で表せない
    case invalidMonth
    /// 今月、予算と異なる通貨の推定費用が記録されている（月の途中で通貨を変えた）。
    /// 換算できない既存の消費を 0 とみなして予算の枠を戻さないよう、表示も判定もしない
    case usageInOtherCurrency
  }

  /// 予算・単価表・集計月をそろえた値
  struct Configuration: Sendable {
    let budget: MonthlyBudget
    let priceTable: PriceTable
    let month: YearMonth
    let usageMonth: UsageMonth
  }

  /// 設定と現在時刻から、今月の予算判定に使う値を作る
  static func configuration(
    for settings: AppSettings, at date: Date, in calendar: Calendar
  ) throws(Unavailable) -> Configuration {
    guard let budgetSetting = settings.monthlyBudget else { throw .budgetNotSet }
    guard let priceTable = priceTable(from: settings.priceTable) else {
      throw .priceTableIncomplete
    }
    guard
      let budget = try? MonthlyBudget(
        limitAmount: budgetSetting.limitAmount,
        currency: CostCurrency(code: budgetSetting.currencyCode))
    else { throw .budgetNotSet }
    guard budget.currency == priceTable.currency else { throw .currencyMismatch }
    let components = calendar.dateComponents([.year, .month], from: date)
    guard let year = components.year, let monthNumber = components.month,
      let month = try? YearMonth(year: year, month: monthNumber),
      let usageMonth = try? UsageMonth(year: year, month: monthNumber)
    else { throw .invalidMonth }
    return Configuration(
      budget: budget, priceTable: priceTable, month: month, usageMonth: usageMonth)
  }

  /// 保存した単価表を UtterAI の単価表にする。通貨か更新日が未設定なら `nil`（AI-05: 単価表は更新日つき）
  static func priceTable(from setting: PriceTableSetting) -> PriceTable? {
    guard let code = setting.currencyCode, let day = setting.updatedOn,
      let currency = try? CostCurrency(code: code),
      let updatedOn = try? CivilDate(year: day.year, month: day.month, day: day.day)
    else { return nil }
    var prices: [ModelPrice] = []
    for price in setting.prices {
      guard
        let converted = try? ModelPrice(
          model: price.model, inputPerMillionTokens: price.inputPerMillionTokens,
          outputPerMillionTokens: price.outputPerMillionTokens)
      else { return nil }
      prices.append(converted)
    }
    return try? PriceTable(currency: currency, updatedOn: updatedOn, prices: prices)
  }

  /// 保存済みの累計から、予算の通貨の台帳を復元する。ほかの通貨の累計は含めない（為替換算はしない）
  static func ledger(
    currency: CostCurrency, entries: [MonthlyUsageEntry]
  ) throws -> MonthlyUsageLedger {
    var spentByMonth: [YearMonth: Decimal] = [:]
    for entry in entries where entry.currencyCode == currency.code {
      spentByMonth[try YearMonth(year: entry.month.year, month: entry.month.month)] = entry.amount
    }
    return try MonthlyUsageLedger(currency: currency, spentByMonth: spentByMonth)
  }

  /// 今月に予算と異なる通貨の記録があれば `usageInOtherCurrency` を投げる
  static func ensureNoUsageInOtherCurrency(
    configuration: Configuration, entries: [MonthlyUsageEntry]
  ) throws(Unavailable) {
    let code = configuration.budget.currency.code
    guard
      !entries.contains(where: {
        $0.month == configuration.usageMonth && $0.currencyCode != code
      })
    else { throw .usageInOtherCurrency }
  }

  /// 今月の推定費用の表示用の値（AI-05）。保存済みの累計を読むため、メインスレッドの外で呼ぶ
  static func estimatedCostSummary(
    configuration: Configuration, usageStore: MonthlyUsageStore
  ) throws -> EstimatedCostSummary {
    let currency = configuration.budget.currency
    let entries = try usageStore.entries()
    try ensureNoUsageInOtherCurrency(configuration: configuration, entries: entries)
    let ledger = try ledger(currency: currency, entries: entries)
    return try EstimatedCostSummary(
      month: configuration.month, budget: configuration.budget, ledger: ledger,
      priceTable: configuration.priceTable)
  }

  /// 送信前の予算判定と推定費用の記録を行う `BudgetGuard` を、保存済みの累計から作る（AI-04, AI-05）。
  ///
  /// 記録のたびに推定費用を `usageStore` へ加算する。加算に失敗すると `BudgetGuard` は以降の予約を拒否する。
  /// 今月に予算と異なる通貨の記録があれば作らない（`usageInOtherCurrency`）。呼び出し側はクラウドへ送らない。
  /// 保存済みの累計を読むため、メインスレッドの外で呼ぶ
  static func makeBudgetGuard(
    configuration: Configuration, usageStore: MonthlyUsageStore
  ) throws -> BudgetGuard {
    let currency = configuration.budget.currency
    let entries = try usageStore.entries()
    try ensureNoUsageInOtherCurrency(configuration: configuration, entries: entries)
    let ledger = try ledger(currency: currency, entries: entries)
    return BudgetGuard(
      budget: configuration.budget,
      estimator: CostEstimator(priceTable: configuration.priceTable),
      ledger: ledger,
      onRecord: { recorded in
        try usageStore.record(
          recorded.cost.amount, currencyCode: recorded.cost.currency.code,
          in: UsageMonth(year: recorded.month.year, month: recorded.month.month))
      })
  }
}
