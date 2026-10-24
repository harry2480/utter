import Foundation
import Testing

@testable import UtterAI

struct EstimatedCostSummaryTests {
  private let yen = try! CostCurrency(code: "JPY")
  private let october = try! YearMonth(year: 2026, month: 10)
  private let updatedOn = try! CivilDate(year: 2026, month: 10, day: 1)

  private func priceTable(currency: CostCurrency? = nil) throws -> PriceTable {
    try PriceTable(
      currency: currency ?? yen, updatedOn: updatedOn,
      prices: [
        try ModelPrice(
          model: "m", inputPerMillionTokens: Decimal(1_000_000),
          outputPerMillionTokens: Decimal(1_000_000))
      ])
  }

  private func ledger(spent: Decimal) throws -> MonthlyUsageLedger {
    try MonthlyUsageLedger(currency: yen, spentByMonth: [october: spent])
  }

  @Test("AI-05: 今月の推定累計・予約中・上限・推定の残り・単価表の更新日を表示用に組み立てる")
  func buildsSummary() throws {
    let summary = try EstimatedCostSummary(
      month: october, budget: try MonthlyBudget(limitAmount: 100, currency: yen),
      ledger: try ledger(spent: 40), reserved: 25, priceTable: try priceTable())

    #expect(summary.month == october)
    #expect(summary.currency == yen)
    #expect(summary.estimatedSpent == 40)
    #expect(summary.reserved == 25)
    #expect(summary.limitAmount == 100)
    #expect(summary.estimatedRemaining == 35)
    #expect(summary.priceTableUpdatedOn == updatedOn)
  }

  @Test("AI-04: 推定累計が上限を超えていても、推定の残りを負にしない")
  func remainingIsNeverNegative() throws {
    let summary = try EstimatedCostSummary(
      month: october, budget: try MonthlyBudget(limitAmount: 100, currency: yen),
      ledger: try ledger(spent: 120), reserved: 10, priceTable: try priceTable())

    #expect(summary.estimatedRemaining == 0)
  }

  @Test("AI-05: 予算・台帳・単価表の通貨が一致しなければ組み立てない")
  func rejectsCurrencyMismatch() throws {
    let dollar = try CostCurrency(code: "USD")
    let budget = try MonthlyBudget(limitAmount: 100, currency: yen)

    #expect(throws: PricingError.currencyMismatch) {
      try EstimatedCostSummary(
        month: self.october, budget: budget, ledger: MonthlyUsageLedger(currency: dollar),
        priceTable: try self.priceTable())
    }
    #expect(throws: PricingError.currencyMismatch) {
      try EstimatedCostSummary(
        month: self.october, budget: budget, ledger: try self.ledger(spent: 0),
        priceTable: try self.priceTable(currency: dollar))
    }
  }

  @Test("AI-05: 予約中の額が負・非数なら組み立てない")
  func rejectsInvalidReserved() throws {
    let budget = try MonthlyBudget(limitAmount: 100, currency: yen)

    #expect(throws: PricingError.negativeAmount) {
      try EstimatedCostSummary(
        month: self.october, budget: budget, ledger: try self.ledger(spent: 0), reserved: -1,
        priceTable: try self.priceTable())
    }
    #expect(throws: PricingError.invalidAmount) {
      try EstimatedCostSummary(
        month: self.october, budget: budget, ledger: try self.ledger(spent: 0), reserved: .nan,
        priceTable: try self.priceTable())
    }
  }

  @Test("AI-05: BudgetGuard は送信中の予約を含めた表示用の値を返し、確定後は推定累計に移す")
  func budgetGuardSummaryIncludesReservations() async throws {
    let budgetGuard = BudgetGuard(
      budget: try MonthlyBudget(limitAmount: 100, currency: yen),
      estimator: CostEstimator(priceTable: try priceTable()), ledger: try ledger(spent: 10))
    let reservation = try await budgetGuard.reserve(
      model: "m", expectedUsage: TokenUsage(inputTokens: 30, outputTokens: 0), in: october)

    let pending = try await budgetGuard.estimatedCostSummary(in: october)
    #expect(pending.estimatedSpent == 10)
    #expect(pending.reserved == 30)
    #expect(pending.estimatedRemaining == 60)

    await budgetGuard.settle(reservation, actualUsage: TokenUsage(inputTokens: 20, outputTokens: 0))

    let settled = try await budgetGuard.estimatedCostSummary(in: october)
    #expect(settled.estimatedSpent == 30)
    #expect(settled.reserved == 0)
    #expect(settled.estimatedRemaining == 70)
  }
}

extension EstimatedCostSummaryTests {
  @Test("AI-05: BudgetGuard の表示用の値は、別の月の予約を含めない")
  func budgetGuardSummaryExcludesOtherMonths() async throws {
    let november = try YearMonth(year: 2026, month: 11)
    let budgetGuard = BudgetGuard(
      budget: try MonthlyBudget(limitAmount: 100, currency: yen),
      estimator: CostEstimator(priceTable: try priceTable()), ledger: try ledger(spent: 10))
    _ = try await budgetGuard.reserve(
      model: "m", expectedUsage: TokenUsage(inputTokens: 30, outputTokens: 0), in: november)

    let summary = try await budgetGuard.estimatedCostSummary(in: october)

    #expect(summary.reserved == 0)
    #expect(summary.estimatedRemaining == 90)
  }

  @Test("AI-05: BudgetGuard の予算と台帳の通貨が一致しなければ、表示用の値を返さない")
  func budgetGuardSummaryRejectsCurrencyMismatch() async throws {
    let budgetGuard = BudgetGuard(
      budget: try MonthlyBudget(limitAmount: 100, currency: yen),
      estimator: CostEstimator(priceTable: try priceTable()),
      ledger: MonthlyUsageLedger(currency: try CostCurrency(code: "USD")))

    await #expect(throws: PricingError.currencyMismatch) {
      try await budgetGuard.estimatedCostSummary(in: self.october)
    }
  }
}

struct MonthlyUsageLedgerRestoreTests {
  private let yen = try! CostCurrency(code: "JPY")
  private let october = try! YearMonth(year: 2026, month: 10)

  @Test("AI-05: 保存済みの月ごとの累計から台帳を復元し、続けて記録できる")
  func restoresAndContinuesRecording() throws {
    let september = try YearMonth(year: 2026, month: 9)
    var ledger = try MonthlyUsageLedger(
      currency: yen, spentByMonth: [october: Decimal(string: "12.5")!, september: 3])

    try ledger.record(EstimatedCost(amount: 2, currency: yen), in: october)

    #expect(ledger.spent(in: october) == Decimal(string: "14.5")!)
    #expect(ledger.spent(in: september) == 3)
    #expect(ledger.spent(in: try YearMonth(year: 2026, month: 11)) == 0)
  }

  @Test("AI-05: 負・非数の累計は復元しない")
  func rejectsInvalidAmounts() {
    #expect(throws: PricingError.negativeAmount) {
      try MonthlyUsageLedger(currency: self.yen, spentByMonth: [self.october: -1])
    }
    #expect(throws: PricingError.invalidAmount) {
      try MonthlyUsageLedger(currency: self.yen, spentByMonth: [self.october: .nan])
    }
  }

  @Test("AI-05: 空の累計から復元した台帳は、新しい台帳と同じ")
  func restoresEmptyLedger() throws {
    #expect(
      try MonthlyUsageLedger(currency: yen, spentByMonth: [:]) == MonthlyUsageLedger(currency: yen))
  }

  @Test("AI-05: 加算後の累計が数値でなくなる記録は拒否し、累計を変えない")
  func rejectsRecordThatMakesTotalNaN() throws {
    var ledger = try MonthlyUsageLedger(currency: yen, spentByMonth: [october: 5])

    #expect(throws: PricingError.invalidAmount) {
      try ledger.record(EstimatedCost(amount: .nan, currency: self.yen), in: self.october)
    }
    #expect(ledger.spent(in: october) == 5)
  }
}
