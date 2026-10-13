import Foundation
import Testing

@testable import UtterAI

struct MonthlyBudgetTests {
  private let yen = try! CostCurrency(code: "JPY")
  private let october = try! YearMonth(year: 2026, month: 10)
  private let november = try! YearMonth(year: 2026, month: 11)

  private func budget(_ limit: Int) throws -> MonthlyBudget {
    try MonthlyBudget(limit: EstimatedCost(amount: Decimal(limit), currency: yen))
  }

  @Test("AI-05: 累計が予算上限に達していなければ送信を許可する")
  func allowsSendUnderBudget() throws {
    var ledger = MonthlyUsageLedger(currency: yen)
    try ledger.record(EstimatedCost(amount: Decimal(99), currency: yen), in: october)

    try budget(100).ensureCanSend(ledger: ledger, in: october)
  }

  @Test("AI-05: 累計が予算上限に達したら予算超過として送信を止める")
  func blocksSendAtBudget() throws {
    var ledger = MonthlyUsageLedger(currency: yen)
    try ledger.record(EstimatedCost(amount: Decimal(100), currency: yen), in: october)

    #expect(throws: AIProviderError.budgetExceeded) {
      try budget(100).ensureCanSend(ledger: ledger, in: october)
    }
  }

  @Test("AI-05: 予算上限が 0 なら使用前から送信を止める")
  func zeroBudgetBlocksFirstSend() throws {
    let ledger = MonthlyUsageLedger(currency: yen)

    #expect(throws: AIProviderError.budgetExceeded) {
      try budget(0).ensureCanSend(ledger: ledger, in: october)
    }
  }

  @Test("AI-05: 累計は月ごとにリセットされる")
  func budgetResetsEachMonth() throws {
    var ledger = MonthlyUsageLedger(currency: yen)
    try ledger.record(EstimatedCost(amount: Decimal(100), currency: yen), in: october)

    #expect(throws: AIProviderError.budgetExceeded) {
      try budget(100).ensureCanSend(ledger: ledger, in: october)
    }
    try budget(100).ensureCanSend(ledger: ledger, in: november)
    #expect(ledger.spent(in: november) == 0)
  }

  @Test("AI-05: 記録は同じ月に加算される")
  func accumulatesWithinMonth() throws {
    var ledger = MonthlyUsageLedger(currency: yen)
    try ledger.record(EstimatedCost(amount: Decimal(40), currency: yen), in: october)
    try ledger.record(EstimatedCost(amount: Decimal(60), currency: yen), in: october)

    #expect(ledger.spent(in: october) == 100)
    #expect(throws: AIProviderError.budgetExceeded) {
      try budget(100).ensureCanSend(ledger: ledger, in: october)
    }
  }

  @Test("AI-05: 台帳と予算の通貨が異なるときは評価できないため送信を止める")
  func blocksWhenCurrencyDiffers() throws {
    let usd = try CostCurrency(code: "USD")
    let ledger = MonthlyUsageLedger(currency: usd)

    #expect(throws: AIProviderError.budgetExceeded) {
      try budget(100).ensureCanSend(ledger: ledger, in: october)
    }
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

  @Test("AI-05: 予算判定は推定費用であり、請求額ではないことを示す型名を使う")
  func budgetUsesEstimatedCostType() throws {
    let limit = try budget(100).limit

    #expect(String(describing: limit).hasPrefix("EstimatedCost("))
  }
}
