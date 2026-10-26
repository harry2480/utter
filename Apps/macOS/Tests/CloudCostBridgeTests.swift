import Foundation
import Testing
import UtterAI
import UtterPersistence

struct CloudCostBridgeTests {
  private func settings(limit: Decimal = 1) throws -> AppSettings {
    AppSettings(
      priceTable: PriceTableSetting(
        currencyCode: "USD", updatedOn: CalendarDay(year: 2026, month: 10, day: 1),
        prices: [
          try #require(
            ModelPriceSetting(model: "model-a", inputPerMillionTokens: 1, outputPerMillionTokens: 5)
          )
        ]),
      monthlyBudget: MonthlyBudgetSetting(limitAmount: limit, currencyCode: "USD"))
  }

  private func configuration(_ settings: AppSettings) throws -> CloudCostBridge.Configuration {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
    let date = try #require(
      calendar.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 23)))
    return try CloudCostBridge.configuration(for: settings, at: date, in: calendar)
  }

  @Test("AI-05: 保存した単価表を更新日つきの単価表に変換する")
  func priceTableConversion() throws {
    let table = try #require(CloudCostBridge.priceTable(from: try settings().priceTable))
    #expect(table.currency.code == "USD")
    #expect(table.updatedOn == (try CivilDate(year: 2026, month: 10, day: 1)))
    #expect(table.price(for: "model-a")?.outputPerMillionTokens == 5)
  }

  @Test("AI-05: 更新日か通貨がない単価表は変換しない")
  func incompletePriceTableIsNotConverted() {
    #expect(CloudCostBridge.priceTable(from: PriceTableSetting(currencyCode: "USD")) == nil)
    #expect(
      CloudCostBridge.priceTable(
        from: PriceTableSetting(updatedOn: CalendarDay(year: 2026, month: 1, day: 1))) == nil)
  }

  @Test("AI-05: 集計月は注入した暦で決める")
  func monthUsesInjectedCalendar() throws {
    let configuration = try configuration(try settings())
    #expect(configuration.month == (try YearMonth(year: 2026, month: 10)))
    #expect(configuration.usageMonth == (try UsageMonth(year: 2026, month: 10)))
  }

  @Test("AI-05: 台帳は予算の通貨の累計だけから復元する")
  func ledgerUsesBudgetCurrencyOnly() throws {
    let store = MonthlyUsageStore(database: try UtterDatabase.inMemory())
    try store.record(2, currencyCode: "USD", in: UsageMonth(year: 2026, month: 10))
    try store.record(9, currencyCode: "JPY", in: UsageMonth(year: 2026, month: 10))

    let ledger = try CloudCostBridge.ledger(
      currency: try CostCurrency(code: "USD"), entries: try store.entries())

    #expect(ledger.spent(in: try YearMonth(year: 2026, month: 10)) == 2)
  }

  @Test("AI-04, AI-05: 今月に別の通貨の記録があれば BudgetGuard を作らない（予算の枠を戻さない）")
  func budgetGuardRefusesMixedCurrencyMonth() throws {
    let store = MonthlyUsageStore(database: try UtterDatabase.inMemory())
    try store.record(9, currencyCode: "JPY", in: UsageMonth(year: 2026, month: 10))
    let configuration = try configuration(try settings())

    #expect(throws: CloudCostBridge.Unavailable.usageInOtherCurrency) {
      try CloudCostBridge.makeBudgetGuard(configuration: configuration, usageStore: store)
    }
  }

  @Test("AI-04, AI-05: BudgetGuard は保存済みの累計で予算を判定し、記録した推定費用を保存する")
  func budgetGuardIsWiredToUsageStore() async throws {
    let store = MonthlyUsageStore(database: try UtterDatabase.inMemory())
    let usageMonth = try UsageMonth(year: 2026, month: 10)
    try store.record(Decimal(string: "0.5")!, currencyCode: "USD", in: usageMonth)
    let configuration = try configuration(try settings(limit: 1))
    let budgetGuard = try CloudCostBridge.makeBudgetGuard(
      configuration: configuration, usageStore: store)

    // 入力 10 万トークン（0.1 USD）＋出力 2 万トークン（0.1 USD）
    let usage = TokenUsage(inputTokens: 100_000, outputTokens: 20_000)
    let reservation = try await budgetGuard.reserve(
      model: "model-a", expectedUsage: usage, in: configuration.month)
    await budgetGuard.settle(reservation, actualUsage: usage)

    #expect(try store.spent(in: usageMonth, currencyCode: "USD") == Decimal(string: "0.7")!)
    #expect(!(await budgetGuard.hasPersistenceFailure))

    // 累計 0.7 に 0.4 を足すと上限 1 を超える
    let large = TokenUsage(inputTokens: 400_000, outputTokens: 0)
    await #expect(throws: AIProviderError.budgetExceeded) {
      try await budgetGuard.reserve(model: "model-a", expectedUsage: large, in: configuration.month)
    }
  }
}
