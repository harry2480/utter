import Foundation
import Synchronization
import Testing
import UtterCore

@testable import UtterAI

struct RefinementRouterBudgetTests {
  private let yen = try! CostCurrency(code: "JPY")
  private let october = try! YearMonth(year: 2026, month: 10)
  private let request = RefinementRequest(
    text: "えーと明日の会議は10時からです", mode: .natural, style: .polite)

  /// 1トークン 1 円の単価表と、上限 100 円の予算を持つ BudgetGuard
  private func makeGuard(
    spent: Int = 0, onRecord: (@Sendable (RecordedEstimatedCost) throws -> Void)? = nil
  ) throws -> BudgetGuard {
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
      ledger: ledger, onRecord: onRecord)
  }

  private func recorded(_ amount: Int) -> RecordedEstimatedCost {
    RecordedEstimatedCost(
      cost: EstimatedCost(amount: Decimal(amount), currency: yen), month: october)
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
      request, consent: .refinementGranted(), budget: budget(budgetGuard),
      sensitivity: { .allowedInput })

    #expect(outcome.source == .cloud)
    #expect(outcome.recordedCost == recorded(20))
    #expect(await budgetGuard.ledger.spent(in: october) == 20)
  }

  @Test("AI-04: 予算上限を超える見込みなら送信せず、予算超過として退避する")
  func skipsProviderWhenBudgetExceeded() async throws {
    let budgetGuard = try makeGuard(spent: 90)
    let stub = StubAIProvider(behavior: .echo)
    let router = try RefinementRouter(provider: stub)

    let outcome = try await router.refine(
      request, consent: .refinementGranted(), budget: budget(budgetGuard, expected: 30),
      sensitivity: { .allowedInput })

    #expect(await stub.callCount == 0)
    #expect(outcome.fallbackReason == .providerFailed(.budgetExceeded))
    #expect(outcome.recordedCost == nil)
    #expect(await budgetGuard.ledger.spent(in: october) == 90)
  }

  @Test("AC-06: 同意がないときは予約も送信もしない")
  func doesNotReserveWithoutConsent() async throws {
    let budgetGuard = try makeGuard(spent: 70)
    let stub = StubAIProvider(behavior: .echo)
    let router = try RefinementRouter(provider: stub)

    let outcome = try await router.refine(
      request, consent: ConsentState(), budget: budget(budgetGuard, expected: 30),
      sensitivity: { .allowedInput })

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
      request, consent: .refinementGranted(), budget: budget(budgetGuard, expected: 30),
      sensitivity: { .allowedInput })

    #expect(outcome.fallbackReason == .providerFailed(error))
    #expect(outcome.recordedCost == nil)
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
      request, consent: .refinementGranted(), budget: budget(budgetGuard, expected: 30),
      sensitivity: { .allowedInput })

    #expect(outcome.fallbackReason == .providerFailed(error))
    #expect(outcome.recordedCost == recorded(30))
    #expect(await budgetGuard.ledger.spent(in: october) == 40)
  }

  @Test("AI-05: 応答が検証を通らず退避しても、課金された使用量を記録する")
  func settlesUsageWhenValidationFails() async throws {
    let budgetGuard = try makeGuard()
    let stub = StubAIProvider(
      behavior: .respond("", usage: TokenUsage(inputTokens: 15, outputTokens: 5)))
    let router = try RefinementRouter(provider: stub)

    let outcome = try await router.refine(
      request, consent: .refinementGranted(), budget: budget(budgetGuard),
      sensitivity: { .allowedInput })

    #expect(outcome.fallbackReason != nil)
    #expect(outcome.recordedCost == recorded(20))
    #expect(await budgetGuard.ledger.spent(in: october) == 20)
  }

  @Test("AI-05: 応答に使用量がなければ、見込み費用で記録する")
  func settlesExpectedCostWithoutUsage() async throws {
    let budgetGuard = try makeGuard(spent: 10)
    let router = try RefinementRouter(provider: StubAIProvider(behavior: .echo))

    let outcome = try await router.refine(
      request, consent: .refinementGranted(), budget: budget(budgetGuard, expected: 30),
      sensitivity: { .allowedInput })

    #expect(outcome.source == .cloud)
    #expect(outcome.recordedCost == recorded(30))
    #expect(await budgetGuard.ledger.spent(in: october) == 40)
  }

  @Test(
    "AI-05: 送信中に呼び出し元がキャンセルしても、見込み費用で記録してから CancellationError を投げる",
    .timeLimit(.minutes(1)))
  func settlesBeforeThrowingCancellation() async throws {
    let records = Mutex<[RecordedEstimatedCost]>([])
    let budgetGuard = try makeGuard(spent: 10) { recorded in
      records.withLock { $0.append(recorded) }
    }
    let stub = StubAIProvider(behavior: .echo, delay: .seconds(60))
    let router = try RefinementRouter(provider: stub)
    let request = request
    let budget = budget(budgetGuard, expected: 30)
    let task = Task {
      try await router.refine(
        request, consent: .refinementGranted(), budget: budget, sensitivity: { .allowedInput })
    }
    while await stub.callCount == 0 {
      await Task.yield()
    }

    task.cancel()

    await #expect(throws: CancellationError.self) {
      try await task.value
    }
    #expect(await budgetGuard.ledger.spent(in: october) == 40)
    // 結果が返らなくても、永続化のための記録額は onRecord に届く
    #expect(records.withLock { $0 } == [recorded(30)])
  }
}

extension RefinementRouterBudgetTests {
  @Test("AC-12: 機密入力なら予約も送信もせず、台帳を変えない")
  func doesNotReserveForSensitiveInput() async throws {
    let budgetGuard = try makeGuard(spent: 70)
    let stub = StubAIProvider(behavior: .echo)
    let router = try RefinementRouter(provider: stub)

    let outcome = try await router.refine(
      request, consent: .refinementGranted(), budget: budget(budgetGuard, expected: 30),
      sensitivity: { .secureFieldInput })

    #expect(await stub.callCount == 0)
    #expect(outcome.fallbackReason == .sensitiveInputSuppressed)
    #expect(await budgetGuard.ledger.spent(in: october) == 70)
    // 予約が残っていれば、上限ちょうどの見込み費用は許可されない
    _ = try await budgetGuard.reserve(
      model: "m", expectedUsage: TokenUsage(inputTokens: 30, outputTokens: 0), in: october)
  }

  @Test("AC-12: 予約を待つ間に機密入力へ変わったら、送信せずに予約を取り消す")
  func cancelsReservationWhenBecomingSensitive() async throws {
    let budgetGuard = try makeGuard(spent: 70)
    let stub = StubAIProvider(behavior: .echo)
    let router = try RefinementRouter(provider: stub)
    // 予約の前の判定では許可し、予約を待った後の判定から機密入力にする
    let calls = Mutex(0)

    let outcome = try await router.refine(
      request, consent: .refinementGranted(), budget: budget(budgetGuard, expected: 30),
      sensitivity: {
        let count = calls.withLock { count in
          count += 1
          return count
        }
        return count == 1 ? .allowedInput : .secureFieldInput
      })

    #expect(calls.withLock { $0 } == 2)
    #expect(await stub.callCount == 0)
    #expect(
      outcome
        == RefinementOutcome(text: request.text, source: .localFallback(.sensitiveInputSuppressed)))
    #expect(await budgetGuard.ledger.spent(in: october) == 70)
    // 予約が取り消されていれば、もう一度同じ見込み費用を予約できる
    _ = try await budgetGuard.reserve(
      model: "m", expectedUsage: TokenUsage(inputTokens: 30, outputTokens: 0), in: october)
  }

  @Test("AC-12: 予約できなければ、予約の後の判定はせずに予算超過として退避する")
  func reevaluatesOnlyAfterReservation() async throws {
    let budgetGuard = try makeGuard(spent: 90)
    let stub = StubAIProvider(behavior: .echo)
    let router = try RefinementRouter(provider: stub)
    let calls = Mutex(0)

    // 2回目の判定を予約の前に行う実装なら、退避の理由が機密入力になる
    let outcome = try await router.refine(
      request, consent: .refinementGranted(), budget: budget(budgetGuard, expected: 30),
      sensitivity: {
        let count = calls.withLock { count in
          count += 1
          return count
        }
        return count == 1 ? .allowedInput : .secureFieldInput
      })

    #expect(calls.withLock { $0 } == 1)
    #expect(await stub.callCount == 0)
    #expect(outcome.fallbackReason == .providerFailed(.budgetExceeded))
  }

  @Test("AC-12: 予約を待つ間にキャンセルされたら、機密入力に変わっても退避せず、予約を取り消して CancellationError を投げる")
  func cancellationTakesPrecedenceOverSensitiveInput() async throws {
    let budgetGuard = try makeGuard(spent: 70)
    let stub = StubAIProvider(behavior: .echo)
    let router = try RefinementRouter(provider: stub)
    let request = request
    let budget = budget(budgetGuard, expected: 30)
    let calls = Mutex(0)
    let task = Task {
      try await router.refine(
        request, consent: .refinementGranted(), budget: budget,
        sensitivity: {
          let count = calls.withLock { count in
            count += 1
            return count
          }
          // 予約の前の判定の時点でキャンセルし、予約を待った後の確認でキャンセルが見えるようにする
          withUnsafeCurrentTask { $0?.cancel() }
          return count == 1 ? .allowedInput : .secureFieldInput
        })
    }

    await #expect(throws: CancellationError.self) {
      try await task.value
    }
    #expect(await stub.callCount == 0)
    #expect(await budgetGuard.ledger.spent(in: october) == 70)
    // 予約が取り消されていれば、もう一度同じ見込み費用を予約できる
    _ = try await budgetGuard.reserve(
      model: "m", expectedUsage: TokenUsage(inputTokens: 30, outputTokens: 0), in: october)
  }
}

extension RefinementRouterBudgetTests {
  @Test("AC-12: 機密入力なら予約も送信もせず、台帳を変えない")
  func doesNotReserveForSensitiveInput() async throws {
    let budgetGuard = try makeGuard(spent: 70)
    let stub = StubAIProvider(behavior: .echo)
    let router = try RefinementRouter(provider: stub)

    let outcome = try await router.refine(
      request, consent: .refinementGranted(), budget: budget(budgetGuard, expected: 30),
      sensitivity: { .secureFieldInput })

    #expect(await stub.callCount == 0)
    #expect(outcome.fallbackReason == .sensitiveInputSuppressed)
    #expect(await budgetGuard.ledger.spent(in: october) == 70)
    // 予約が残っていれば、上限ちょうどの見込み費用は許可されない
    _ = try await budgetGuard.reserve(
      model: "m", expectedUsage: TokenUsage(inputTokens: 30, outputTokens: 0), in: october)
  }

  @Test("AC-12: 予約を待つ間に機密入力へ変わったら、送信せずに予約を取り消す")
  func cancelsReservationWhenBecomingSensitive() async throws {
    let budgetGuard = try makeGuard(spent: 70)
    let stub = StubAIProvider(behavior: .echo)
    let router = try RefinementRouter(provider: stub)
    // 予約の前の判定では許可し、予約を待った後の判定から機密入力にする
    let calls = Mutex(0)

    let outcome = try await router.refine(
      request, consent: .refinementGranted(), budget: budget(budgetGuard, expected: 30),
      sensitivity: {
        let count = calls.withLock { count in
          count += 1
          return count
        }
        return count == 1 ? .allowedInput : .secureFieldInput
      })

    #expect(calls.withLock { $0 } == 2)
    #expect(await stub.callCount == 0)
    #expect(
      outcome
        == RefinementOutcome(text: request.text, source: .localFallback(.sensitiveInputSuppressed)))
    #expect(await budgetGuard.ledger.spent(in: october) == 70)
    // 予約が取り消されていれば、もう一度同じ見込み費用を予約できる
    _ = try await budgetGuard.reserve(
      model: "m", expectedUsage: TokenUsage(inputTokens: 30, outputTokens: 0), in: october)
  }

  @Test("AC-12: 予約できなければ、予約の後の判定はせずに予算超過として退避する")
  func reevaluatesOnlyAfterReservation() async throws {
    let budgetGuard = try makeGuard(spent: 90)
    let stub = StubAIProvider(behavior: .echo)
    let router = try RefinementRouter(provider: stub)
    let calls = Mutex(0)

    // 2回目の判定を予約の前に行う実装なら、退避の理由が機密入力になる
    let outcome = try await router.refine(
      request, consent: .refinementGranted(), budget: budget(budgetGuard, expected: 30),
      sensitivity: {
        let count = calls.withLock { count in
          count += 1
          return count
        }
        return count == 1 ? .allowedInput : .secureFieldInput
      })

    #expect(calls.withLock { $0 } == 1)
    #expect(await stub.callCount == 0)
    #expect(outcome.fallbackReason == .providerFailed(.budgetExceeded))
  }

  @Test("AC-12: 予約を待つ間にキャンセルされたら、機密入力に変わっても退避せず、予約を取り消して CancellationError を投げる")
  func cancellationTakesPrecedenceOverSensitiveInput() async throws {
    let budgetGuard = try makeGuard(spent: 70)
    let stub = StubAIProvider(behavior: .echo)
    let router = try RefinementRouter(provider: stub)
    let request = request
    let budget = budget(budgetGuard, expected: 30)
    let calls = Mutex(0)
    let task = Task {
      try await router.refine(
        request, consent: .refinementGranted(), budget: budget,
        sensitivity: {
          let count = calls.withLock { count in
            count += 1
            return count
          }
          // 予約の前の判定の時点でキャンセルし、予約を待った後の確認でキャンセルが見えるようにする
          withUnsafeCurrentTask { $0?.cancel() }
          return count == 1 ? .allowedInput : .secureFieldInput
        })
    }

    await #expect(throws: CancellationError.self) {
      try await task.value
    }
    #expect(await stub.callCount == 0)
    #expect(await budgetGuard.ledger.spent(in: october) == 70)
    // 予約が取り消されていれば、もう一度同じ見込み費用を予約できる
    _ = try await budgetGuard.reserve(
      model: "m", expectedUsage: TokenUsage(inputTokens: 30, outputTokens: 0), in: october)
  }
}
