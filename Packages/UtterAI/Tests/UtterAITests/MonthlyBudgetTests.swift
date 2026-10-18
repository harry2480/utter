import Foundation
import Testing

@testable import UtterAI

struct MonthlyBudgetTests {
  private let yen = try! CostCurrency(code: "JPY")
  private let october = try! YearMonth(year: 2026, month: 10)
  private let november = try! YearMonth(year: 2026, month: 11)
  /// 入力・出力とも 100万トークンあたり 1,000,000 円（1トークン 1 円）
  private let estimator = CostEstimator(
    priceTable: try! PriceTable(
      currency: try! CostCurrency(code: "JPY"),
      updatedOn: try! CivilDate(year: 2026, month: 10, day: 1),
      prices: [
        try! ModelPrice(
          model: "m", inputPerMillionTokens: Decimal(1_000_000),
          outputPerMillionTokens: Decimal(1_000_000))
      ]))

  private func budget(_ limit: Int) throws -> MonthlyBudget {
    try MonthlyBudget(limitAmount: Decimal(limit), currency: yen)
  }

  private func ledger(spent: Int, in month: YearMonth) throws -> MonthlyUsageLedger {
    var ledger = MonthlyUsageLedger(currency: yen)
    try ledger.record(EstimatedCost(amount: Decimal(spent), currency: yen), in: month)
    return ledger
  }

  private func usage(_ tokens: Int) -> TokenUsage {
    TokenUsage(inputTokens: tokens, outputTokens: 0)
  }

  private func check(
    _ budget: MonthlyBudget, _ ledger: MonthlyUsageLedger, expected tokens: Int,
    model: String = "m", estimator: CostEstimator? = nil, in month: YearMonth? = nil
  ) -> BudgetDecision {
    budget.check(
      model: model, expectedUsage: usage(tokens), estimator: estimator ?? self.estimator,
      ledger: ledger, in: month ?? october)
  }

  @Test("AI-05: 累計と今回の見込み費用が上限に収まれば送信を許可する")
  func allowsSendWithinBudget() throws {
    let ledger = try ledger(spent: 90, in: october)

    #expect(check(try budget(100), ledger, expected: 10) == .allowed)
    try budget(100).ensureCanSend(
      model: "m", expectedUsage: usage(10), estimator: estimator, ledger: ledger, in: october)
  }

  @Test("AI-05: 累計と今回の見込み費用の合計が上限を超えるなら送信を止める")
  func blocksWhenPendingCostExceedsBudget() throws {
    let ledger = try ledger(spent: 95, in: october)

    #expect(check(try budget(100), ledger, expected: 10) == .exceeded)
    #expect(throws: AIProviderError.budgetExceeded) {
      try budget(100).ensureCanSend(
        model: "m", expectedUsage: usage(10), estimator: estimator, ledger: ledger, in: october)
    }
  }

  @Test("AI-05: 累計が上限に達していれば、見込み費用が 0 でも送信を止める")
  func blocksAtBudgetEvenWithZeroPending() throws {
    #expect(check(try budget(100), try ledger(spent: 100, in: october), expected: 0) == .exceeded)
    #expect(check(try budget(0), MonthlyUsageLedger(currency: yen), expected: 0) == .exceeded)
  }

  @Test("AI-05: 累計は月ごとにリセットされる")
  func budgetResetsEachMonth() throws {
    let ledger = try ledger(spent: 100, in: october)

    #expect(check(try budget(100), ledger, expected: 1) == .exceeded)
    #expect(check(try budget(100), ledger, expected: 1, in: november) == .allowed)
    #expect(ledger.spent(in: november) == 0)
  }

  @Test("AI-05: 記録は同じ月に加算される")
  func accumulatesWithinMonth() throws {
    var ledger = MonthlyUsageLedger(currency: yen)
    try ledger.record(EstimatedCost(amount: Decimal(40), currency: yen), in: october)
    try ledger.record(EstimatedCost(amount: Decimal(60), currency: yen), in: october)

    #expect(ledger.spent(in: october) == 100)
  }

  @Test("AI-05: 単価表にないモデルは費用を推定できないため送信を止める（0 円扱いにしない）")
  func blocksUnknownModel() throws {
    let ledger = MonthlyUsageLedger(currency: yen)

    #expect(
      check(try budget(100), ledger, expected: 1, model: "unknown")
        == .cannotEstimate(.estimationFailed(.unknownModel("unknown"))))
    #expect(throws: AIProviderError.budgetExceeded) {
      try budget(100).ensureCanSend(
        model: "unknown", expectedUsage: usage(1), estimator: estimator, ledger: ledger,
        in: october)
    }
  }

  @Test("AI-05: 単価表が空（初期値が未設定）なら費用を推定できないため送信を止める")
  func blocksWhenPriceTableIsEmpty() throws {
    let emptyEstimator = CostEstimator(
      priceTable: try PriceTable(
        currency: yen, updatedOn: try CivilDate(year: 2026, month: 10, day: 1), prices: []))

    #expect(
      check(
        try budget(100), MonthlyUsageLedger(currency: yen), expected: 0, estimator: emptyEstimator)
        == .cannotEstimate(.estimationFailed(.unknownModel("m"))))
  }

  @Test("AI-05: 予算・台帳・単価表の通貨が一致しないときは評価できないため送信を止める")
  func blocksWhenCurrencyDiffers() throws {
    let usd = try CostCurrency(code: "USD")
    let usdEstimator = CostEstimator(
      priceTable: try PriceTable(
        currency: usd, updatedOn: try CivilDate(year: 2026, month: 10, day: 1),
        prices: estimator.priceTable.prices))

    #expect(
      check(try budget(100), MonthlyUsageLedger(currency: usd), expected: 1)
        == .cannotEstimate(.currencyMismatch))
    #expect(
      check(
        try budget(100), MonthlyUsageLedger(currency: yen), expected: 1, estimator: usdEstimator)
        == .cannotEstimate(.currencyMismatch))
  }

  @Test("AI-05: 台帳は通貨が異なる推定費用を記録しない")
  func ledgerRejectsOtherCurrency() throws {
    let usd = try CostCurrency(code: "USD")
    var ledger = MonthlyUsageLedger(currency: yen)

    #expect(throws: PricingError.currencyMismatch) {
      try ledger.record(EstimatedCost(amount: Decimal(1), currency: usd), in: october)
    }
    #expect(ledger.spent(in: october) == 0)
  }
}
