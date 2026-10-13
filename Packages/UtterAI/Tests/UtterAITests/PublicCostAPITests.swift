import Foundation
import Testing
import UtterAI

/// `@testable` を付けず、アプリ側から使える公開 API だけで予算判定を組み立てられることを確かめる。
struct PublicCostAPITests {
  @Test("AI-05: 公開 API だけで単価表・推定費用・予算判定を組み立てられる")
  func buildsBudgetCheckWithPublicAPI() throws {
    let yen = try CostCurrency(code: "JPY")
    let october = try YearMonth(year: 2026, month: 10)
    let estimator = CostEstimator(
      priceTable: try PriceTable(
        currency: yen,
        updatedOn: try CivilDate(year: 2026, month: 10, day: 1),
        prices: [
          try ModelPrice(
            model: "m", inputPerMillionTokens: Decimal(1_000_000),
            outputPerMillionTokens: Decimal(1_000_000))
        ]))
    let budget = try MonthlyBudget(limitAmount: Decimal(100), currency: yen)
    var ledger = MonthlyUsageLedger(currency: yen)

    let cost = try estimator.estimate(
      model: "m", usage: TokenUsage(inputTokens: 60, outputTokens: 30))
    try ledger.record(cost, in: october)

    #expect(ledger.spent(in: october) == Decimal(90))
    #expect(
      budget.check(
        model: "m", expectedUsage: TokenUsage(inputTokens: 10, outputTokens: 0),
        estimator: estimator, ledger: ledger, in: october) == .allowed)
    #expect(
      budget.check(
        model: "m", expectedUsage: TokenUsage(inputTokens: 11, outputTokens: 0),
        estimator: estimator, ledger: ledger, in: october) == .exceeded)
  }
}
