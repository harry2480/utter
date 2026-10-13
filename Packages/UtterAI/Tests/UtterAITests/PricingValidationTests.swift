import Foundation
import Testing

@testable import UtterAI

struct PricingValidationTests {
  @Test("AI-05: 通貨コードは空や空白だけを拒否する", arguments: ["", "  \n"])
  func rejectsEmptyCurrencyCode(_ code: String) {
    #expect(throws: PricingError.emptyCurrencyCode) {
      try CostCurrency(code: code)
    }
  }

  @Test("AI-05: 通貨コードは前後の空白を除いて大文字にそろえる")
  func normalizesCurrencyCode() throws {
    #expect(try CostCurrency(code: " jpy ") == CostCurrency(code: "JPY"))
    #expect(try CostCurrency(code: "jpy").code == "JPY")
  }

  @Test("AI-05: モデル名は空を拒否する")
  func rejectsEmptyModelName() {
    #expect(throws: PricingError.emptyModelName) {
      try ModelPrice(
        model: "", inputPerMillionTokens: Decimal(1), outputPerMillionTokens: Decimal(1))
    }
  }

  @Test("AI-05: 負の単価は拒否する", arguments: [(-1, 0), (0, -1)])
  func rejectsNegativePrice(_ input: Int, _ output: Int) {
    #expect(throws: PricingError.negativePrice) {
      try ModelPrice(
        model: "m", inputPerMillionTokens: Decimal(input), outputPerMillionTokens: Decimal(output))
    }
  }

  @Test("AI-05: 日付と月の範囲外を拒否する")
  func rejectsInvalidDateAndMonth() {
    #expect(throws: PricingError.invalidDate) {
      try CivilDate(year: 2026, month: 13, day: 1)
    }
    #expect(throws: PricingError.invalidDate) {
      try CivilDate(year: 2026, month: 1, day: 0)
    }
    #expect(throws: PricingError.invalidMonth) {
      try YearMonth(year: 2026, month: 0)
    }
  }

  @Test("AI-05: 推定費用の加算は同じ通貨の場合だけ行う")
  func addsOnlySameCurrency() throws {
    let yen = try CostCurrency(code: "JPY")
    let usd = try CostCurrency(code: "USD")
    let cost = EstimatedCost(amount: Decimal(3), currency: yen)

    let sum = try cost.adding(EstimatedCost(amount: Decimal(4), currency: yen))
    #expect(sum.amount == Decimal(7))

    #expect(throws: PricingError.currencyMismatch) {
      try cost.adding(EstimatedCost(amount: Decimal(4), currency: usd))
    }
  }

  @Test("AI-05: 予算上限の負の値は拒否する")
  func rejectsNegativeBudget() throws {
    let yen = try CostCurrency(code: "JPY")

    #expect(throws: PricingError.negativeAmount) {
      try MonthlyBudget(limitAmount: Decimal(-1), currency: yen)
    }
  }
}
