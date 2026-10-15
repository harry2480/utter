import Foundation
import Testing

@testable import UtterAI

struct CostEstimatorTests {
  private let yen = try! CostCurrency(code: "JPY")
  private let usdLike = try! CostCurrency(code: "USD")

  private func priceTable(
    currency: CostCurrency? = nil,
    prices: [ModelPrice]? = nil
  ) throws -> PriceTable {
    try PriceTable(
      currency: currency ?? yen,
      updatedOn: try CivilDate(year: 2026, month: 10, day: 1),
      prices: prices ?? [
        try ModelPrice(
          model: "small-model",
          inputPerMillionTokens: Decimal(100),
          outputPerMillionTokens: Decimal(500)),
        try ModelPrice(
          model: "zero-model",
          inputPerMillionTokens: Decimal(0),
          outputPerMillionTokens: Decimal(0)),
      ]
    )
  }

  @Test("AI-05: トークン使用量と単価から推定費用を計算する")
  func estimatesCostFromUsageAndPrice() throws {
    let estimator = CostEstimator(priceTable: try priceTable())
    let usage = TokenUsage(inputTokens: 2_000_000, outputTokens: 1_000_000)

    let cost = try estimator.estimate(model: "small-model", usage: usage)

    // 入力 2M × 100 + 出力 1M × 500 = 700
    #expect(cost.amount == Decimal(700))
    #expect(cost.currency == yen)
  }

  @Test("AI-05: 金額は浮動小数の誤差を出さない（端数が正確に出る）")
  func keepsExactDecimalAmounts() throws {
    let estimator = CostEstimator(priceTable: try priceTable())
    let usage = TokenUsage(inputTokens: 1, outputTokens: 3)

    let cost = try estimator.estimate(model: "small-model", usage: usage)

    // 1 × 100 / 1e6 + 3 × 500 / 1e6 = 0.0001 + 0.0015 = 0.0016
    #expect(cost.amount == Decimal(string: "0.0016"))
  }

  @Test("AI-05: 使用量がゼロなら推定費用もゼロ")
  func zeroUsageIsZeroCost() throws {
    let estimator = CostEstimator(priceTable: try priceTable())

    let cost = try estimator.estimate(
      model: "small-model", usage: TokenUsage(inputTokens: 0, outputTokens: 0))

    #expect(cost.amount == 0)
  }

  @Test("AI-05: 単価表にないモデルは推定不可として扱い、0 円にしない")
  func unknownModelIsNotZero() throws {
    let estimator = CostEstimator(priceTable: try priceTable())

    #expect(throws: CostEstimationError.unknownModel("missing-model")) {
      try estimator.estimate(
        model: "missing-model", usage: TokenUsage(inputTokens: 10, outputTokens: 10))
    }
  }

  @Test("AI-05: 単価が 0 のモデルは 0 円として推定できる（推定不可とは区別する）")
  func zeroPricedModelIsEstimated() throws {
    let estimator = CostEstimator(priceTable: try priceTable())

    let cost = try estimator.estimate(
      model: "zero-model", usage: TokenUsage(inputTokens: 10, outputTokens: 10))

    #expect(cost.amount == 0)
  }

  @Test("AI-05: 負のトークン数は推定しない")
  func rejectsNegativeTokenCount() throws {
    let estimator = CostEstimator(priceTable: try priceTable())

    #expect(throws: CostEstimationError.negativeTokenCount) {
      try estimator.estimate(
        model: "small-model", usage: TokenUsage(inputTokens: -1, outputTokens: 0))
    }
    #expect(throws: CostEstimationError.negativeTokenCount) {
      try estimator.estimate(
        model: "small-model", usage: TokenUsage(inputTokens: 0, outputTokens: -1))
    }
  }

  @Test("AI-05: 単価表は利用者の設定値として渡し、通貨と更新日を保持する")
  func priceTableKeepsCurrencyAndUpdateDate() throws {
    let table = try priceTable(currency: usdLike)
    let expectedDate = try CivilDate(year: 2026, month: 10, day: 1)

    #expect(table.currency == usdLike)
    #expect(table.updatedOn == expectedDate)
    #expect(table.price(for: "small-model")?.inputPerMillionTokens == Decimal(100))
    #expect(table.price(for: "missing-model") == nil)
  }

  @Test("AI-05: 同じモデル名の単価を2つ持つ単価表は拒否する")
  func rejectsDuplicateModels() throws {
    let price = try ModelPrice(
      model: "dup", inputPerMillionTokens: Decimal(1), outputPerMillionTokens: Decimal(1))

    #expect(throws: PricingError.duplicateModel("dup")) {
      try PriceTable(
        currency: yen,
        updatedOn: try CivilDate(year: 2026, month: 10, day: 1),
        prices: [price, price])
    }
  }

  @Test("AI-05: 推定費用の文字列表現に通貨と金額だけを出す")
  func costDescriptionHasOnlyAmountAndCurrency() throws {
    let cost = EstimatedCost(amount: Decimal(700), currency: yen)

    #expect(String(describing: cost) == "EstimatedCost(amount: 700, currency: JPY)")
  }
}
