import Foundation
import Testing

@testable import UtterAI

struct BudgetGuardTests {
  private let yen = try! CostCurrency(code: "JPY")
  private let october = try! YearMonth(year: 2026, month: 10)

  /// 1トークン 1 円の単価表と、上限 100 円の予算を持つ BudgetGuard
  private func makeGuard(spent: Int = 0) throws -> BudgetGuard {
    let estimator = CostEstimator(
      priceTable: try PriceTable(
        currency: yen, updatedOn: try CivilDate(year: 2026, month: 10, day: 1),
        prices: [
          try ModelPrice(
            model: "m", inputPerMillionTokens: Decimal(1_000_000),
            outputPerMillionTokens: Decimal(1_000_000))
        ]))
    var ledger = MonthlyUsageLedger(currency: yen)
    try ledger.record(EstimatedCost(amount: Decimal(spent), currency: yen), in: october)
    return BudgetGuard(
      budget: try MonthlyBudget(limitAmount: Decimal(100), currency: yen), estimator: estimator,
      ledger: ledger)
  }

  private func usage(_ tokens: Int) -> TokenUsage {
    TokenUsage(inputTokens: tokens, outputTokens: 0)
  }

  @Test("AI-05: 予約中の見込み費用も判定に含め、並行送信で上限を超えて許可しない")
  func includesReservationsInDecision() async throws {
    let budgetGuard = try makeGuard(spent: 40)

    let first = try await budgetGuard.reserve(model: "m", expectedUsage: usage(30), in: october)
    let second = try await budgetGuard.reserve(model: "m", expectedUsage: usage(30), in: october)
    await #expect(throws: AIProviderError.budgetExceeded) {
      try await budgetGuard.reserve(model: "m", expectedUsage: usage(1), in: october)
    }

    #expect(first.amount == 30)
    #expect(second.amount == 30)
  }

  @Test("AI-05: 同時に予約しても、上限に収まる件数だけ許可する")
  func concurrentReservationsStayWithinBudget() async throws {
    let budgetGuard = try makeGuard()
    let month = october

    let allowed = await withTaskGroup(of: Bool.self) { group in
      for _ in 0..<10 {
        group.addTask {
          (try? await budgetGuard.reserve(
            model: "m", expectedUsage: TokenUsage(inputTokens: 30, outputTokens: 0), in: month))
            != nil
        }
      }
      return await group.reduce(0) { $0 + ($1 ? 1 : 0) }
    }

    #expect(allowed == 3)
  }

  @Test("AI-05: 確定すると実際の使用量の推定費用を記録し、予約を解放する")
  func settlesWithActualUsage() async throws {
    let budgetGuard = try makeGuard()
    let reservation = try await budgetGuard.reserve(
      model: "m", expectedUsage: usage(80), in: october)

    await budgetGuard.settle(reservation, actualUsage: usage(20))

    #expect(await budgetGuard.ledger.spent(in: october) == 20)
    _ = try await budgetGuard.reserve(model: "m", expectedUsage: usage(80), in: october)
  }

  @Test(
    "AI-05: 実際の使用量が不明・推定不可なら予約した見込み費用を記録する",
    arguments: [nil, TokenUsage(inputTokens: -1, outputTokens: 0)])
  func settlesWithReservedAmountWhenUsageUnknown(_ actual: TokenUsage?) async throws {
    let budgetGuard = try makeGuard()
    let reservation = try await budgetGuard.reserve(
      model: "m", expectedUsage: usage(30), in: october)

    await budgetGuard.settle(reservation, actualUsage: actual)

    #expect(await budgetGuard.ledger.spent(in: october) == 30)
  }

  @Test("AI-05: 確定・取り消し済みの予約をもう一度確定しても記録しない")
  func settlingTwiceRecordsOnce() async throws {
    let budgetGuard = try makeGuard()
    let settled = try await budgetGuard.reserve(model: "m", expectedUsage: usage(30), in: october)
    let cancelled = try await budgetGuard.reserve(model: "m", expectedUsage: usage(30), in: october)

    await budgetGuard.settle(settled, actualUsage: usage(30))
    await budgetGuard.settle(settled, actualUsage: usage(30))
    await budgetGuard.cancel(cancelled)
    await budgetGuard.settle(cancelled, actualUsage: usage(30))

    #expect(await budgetGuard.ledger.spent(in: october) == 30)
  }

  @Test("AI-05: 取り消すと台帳に記録せず予約を解放する")
  func cancelReleasesReservation() async throws {
    let budgetGuard = try makeGuard(spent: 40)
    let reservation = try await budgetGuard.reserve(
      model: "m", expectedUsage: usage(60), in: october)

    await budgetGuard.cancel(reservation)

    #expect(await budgetGuard.ledger.spent(in: october) == 40)
    _ = try await budgetGuard.reserve(model: "m", expectedUsage: usage(60), in: october)
  }

  @Test("AI-05: 推定できない送信は予約しない")
  func doesNotReserveUnknownModel() async throws {
    let budgetGuard = try makeGuard()

    await #expect(throws: AIProviderError.budgetExceeded) {
      try await budgetGuard.reserve(model: "unknown", expectedUsage: usage(1), in: october)
    }
  }
}
