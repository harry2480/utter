import Foundation
import Testing

@testable import UtterAI

struct RefinementRouterBudgetTests {
  private let yen = try! CostCurrency(code: "JPY")
  private let october = try! YearMonth(year: 2026, month: 10)
  private let request = RefinementRequest(
    text: "えーと明日の会議は10時からです", mode: .natural, style: .polite)

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

  private func budget(_ budgetGuard: BudgetGuard, expected tokens: Int = 30) -> RefinementBudget {
    RefinementBudget(
      guard: budgetGuard, model: "m",
      expectedUsage: TokenUsage(inputTokens: tokens, outputTokens: 0), month: october)
  }

  @Test("AI-05: 応答があれば、実際の使用量で推定費用を記録する")
  func settlesWithActualUsage() async throws {
    let budgetGuard = try makeGuard()
    let stub = StubAIProvider(
      behavior: .respond(
        "明日の会議は10時からです。", usage: TokenUsage(inputTokens: 12, outputTokens: 8)))
    let router = try RefinementRouter(provider: stub)

    let outcome = try await router.refine(
      request, cloudConsentGranted: true, budget: budget(budgetGuard))

    #expect(outcome.source == .cloud)
    #expect(await budgetGuard.ledger.spent(in: october) == 20)
  }

  @Test("AI-04: 予算上限を超える見込みなら送信せず、予算超過として退避する")
  func skipsProviderWhenBudgetExceeded() async throws {
    let budgetGuard = try makeGuard(spent: 90)
    let stub = StubAIProvider(behavior: .echo)
    let router = try RefinementRouter(provider: stub)

    let outcome = try await router.refine(
      request, cloudConsentGranted: true, budget: budget(budgetGuard, expected: 30))

    #expect(await stub.callCount == 0)
    #expect(outcome.fallbackReason == .providerFailed(.budgetExceeded))
    #expect(await budgetGuard.ledger.spent(in: october) == 90)
  }

  @Test("AC-06: 同意がないときは予約も送信もしない")
  func doesNotReserveWithoutConsent() async throws {
    let budgetGuard = try makeGuard(spent: 70)
    let stub = StubAIProvider(behavior: .echo)
    let router = try RefinementRouter(provider: stub)

    let outcome = try await router.refine(
      request, cloudConsentGranted: false, budget: budget(budgetGuard, expected: 30))

    #expect(await stub.callCount == 0)
    #expect(outcome.fallbackReason == .consentNotGranted)
    // 予約が残っていれば、上限ちょうどの見込み費用は許可されない
    let reservation = try await budgetGuard.reserve(
      model: "m", expectedUsage: TokenUsage(inputTokens: 30, outputTokens: 0), in: october)
    await budgetGuard.cancel(reservation)
  }

  @Test(
    "AI-05: 課金されない失敗は予約を取り消し、記録しない",
    arguments: [AIProviderError.authenticationExpired, .quotaExceeded])
  func cancelsReservationWhenNotCharged(_ error: AIProviderError) async throws {
    let budgetGuard = try makeGuard(spent: 70)
    let router = try RefinementRouter(provider: StubAIProvider(behavior: .fail(error)))

    let outcome = try await router.refine(
      request, cloudConsentGranted: true, budget: budget(budgetGuard, expected: 30))

    #expect(outcome.fallbackReason == .providerFailed(error))
    #expect(await budgetGuard.ledger.spent(in: october) == 70)
    // 予約が取り消されていれば、もう一度同じ見込み費用を予約できる
    _ = try await budgetGuard.reserve(
      model: "m", expectedUsage: TokenUsage(inputTokens: 30, outputTokens: 0), in: october)
  }

  @Test(
    "AI-05: 課金されている可能性がある失敗は、見込み費用で記録する",
    arguments: [AIProviderError.timeout, .invalidResponse, .cancelled, .networkUnavailable])
  func settlesExpectedCostWhenPossiblyCharged(_ error: AIProviderError) async throws {
    let budgetGuard = try makeGuard(spent: 10)
    let router = try RefinementRouter(provider: StubAIProvider(behavior: .fail(error)))

    let outcome = try await router.refine(
      request, cloudConsentGranted: true, budget: budget(budgetGuard, expected: 30))

    #expect(outcome.fallbackReason == .providerFailed(error))
    #expect(await budgetGuard.ledger.spent(in: october) == 40)
  }

  @Test("AI-05: 応答が検証を通らず退避しても、課金された使用量を記録する")
  func settlesUsageWhenValidationFails() async throws {
    let budgetGuard = try makeGuard()
    let stub = StubAIProvider(
      behavior: .respond("", usage: TokenUsage(inputTokens: 15, outputTokens: 5)))
    let router = try RefinementRouter(provider: stub)

    let outcome = try await router.refine(
      request, cloudConsentGranted: true, budget: budget(budgetGuard))

    #expect(outcome.fallbackReason != nil)
    #expect(await budgetGuard.ledger.spent(in: october) == 20)
  }

  @Test("AI-05: 応答に使用量がなければ、見込み費用で記録する")
  func settlesExpectedCostWithoutUsage() async throws {
    let budgetGuard = try makeGuard(spent: 10)
    let router = try RefinementRouter(provider: StubAIProvider(behavior: .echo))

    let outcome = try await router.refine(
      request, cloudConsentGranted: true, budget: budget(budgetGuard, expected: 30))

    #expect(outcome.source == .cloud)
    #expect(await budgetGuard.ledger.spent(in: october) == 40)
  }

  @Test(
    "AI-05: 送信中に呼び出し元がキャンセルしても、見込み費用で記録してから CancellationError を投げる",
    .timeLimit(.minutes(1)))
  func settlesBeforeThrowingCancellation() async throws {
    let budgetGuard = try makeGuard(spent: 10)
    let stub = StubAIProvider(behavior: .echo, delay: .seconds(60))
    let router = try RefinementRouter(provider: stub)
    let request = request
    let budget = budget(budgetGuard, expected: 30)
    let task = Task {
      try await router.refine(request, cloudConsentGranted: true, budget: budget)
    }
    while await stub.callCount == 0 {
      await Task.yield()
    }

    task.cancel()

    await #expect(throws: CancellationError.self) {
      try await task.value
    }
    #expect(await budgetGuard.ledger.spent(in: october) == 40)
  }
}
