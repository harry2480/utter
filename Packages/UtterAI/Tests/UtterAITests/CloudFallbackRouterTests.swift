import Foundation
import Synchronization
import Testing
import UtterCore

@testable import UtterAI

struct CloudFallbackRouterTests {
  /// テストの途中で書き換えられる同意状態
  private final class MutableConsent: Sendable {
    let state: Mutex<ConsentState>

    init(_ consent: ConsentState) {
      state = Mutex(consent)
    }
  }

  private let yen = try! CostCurrency(code: "JPY")
  private let october = try! YearMonth(year: 2026, month: 10)
  private let request = RefinementRequest(
    text: "えーと明日の会議は10時からです", mode: .natural, style: .polite)

  /// 指定した送信先への整形の同意と、必要なら自動フォールバックへの同意を付与した状態を返す
  private func consent(
    _ destinations: [CloudAIProviderKind], fallback: Bool
  ) -> @Sendable () -> ConsentState {
    var consent = ConsentState()
    for destination in destinations {
      consent.grant(.transmission(.textRefinement(destination)))
    }
    if fallback {
      consent.grant(.crossProviderFallback)
    }
    let granted = consent
    return { granted }
  }

  private func route(_ provider: StubAIProvider, budget: RefinementBudget? = nil) -> RefinementRoute
  {
    RefinementRoute(provider: provider, budget: budget)
  }

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

  @Test(
    "AI-04: 自動フォールバックの同意がなければ、両方の送信先に同意していても1回だけ送信して退避する",
    arguments: AIProviderError.allCases.filter { $0 != .cancelled })
  func doesNotFallBackWithoutPermission(_ error: AIProviderError) async throws {
    let claude = StubAIProvider(behavior: .fail(error), destination: .claude)
    let chatGPT = StubAIProvider(behavior: .echo, destination: .chatGPT)
    let router = try CloudFallbackRouter()

    let outcome = try await router.refine(
      request, consent: consent([.claude, .chatGPT], fallback: false), primary: route(claude),
      fallbacks: [route(chatGPT)])

    #expect(await claude.callCount == 1)
    #expect(await chatGPT.callCount == 0)
    #expect(
      outcome
        == RefinementOutcome(text: request.text, source: .localFallback(.providerFailed(error)))
    )
  }

  @Test(
    "AI-04: 許可があれば、課金されない失敗のときに同意のある別の送信先へ切り替える",
    arguments: [AIProviderError.authenticationExpired, .quotaExceeded, .budgetExceeded])
  func fallsBackOnUnbilledFailure(_ error: AIProviderError) async throws {
    let claude = StubAIProvider(behavior: .fail(error), destination: .claude)
    let chatGPT = StubAIProvider(
      behavior: .respond("明日の会議は10時からです。"), destination: .chatGPT)
    let router = try CloudFallbackRouter()

    let outcome = try await router.refine(
      request, consent: consent([.claude, .chatGPT], fallback: true), primary: route(claude),
      fallbacks: [route(chatGPT)])

    #expect(await claude.callCount == 1)
    #expect(await chatGPT.receivedRequests == [request])
    #expect(outcome == RefinementOutcome(text: "明日の会議は10時からです。", source: .cloud))
  }

  @Test(
    "AI-04: 課金されている可能性がある失敗や検証失敗では、許可があっても切り替えない",
    arguments: [
      StubAIProvider.Behavior.fail(.timeout), .fail(.networkUnavailable), .fail(.invalidResponse),
      .fail(.cancelled), .respond(""),
    ])
  func doesNotFallBackOnPossiblyBilledFailure(_ behavior: StubAIProvider.Behavior) async throws {
    let claude = StubAIProvider(behavior: behavior, destination: .claude)
    let chatGPT = StubAIProvider(behavior: .echo, destination: .chatGPT)
    let router = try CloudFallbackRouter()

    let outcome = try await router.refine(
      request, consent: consent([.claude, .chatGPT], fallback: true), primary: route(claude),
      fallbacks: [route(chatGPT)])

    #expect(await claude.callCount == 1)
    #expect(await chatGPT.callCount == 0)
    #expect(outcome.fallbackReason != nil)
    #expect(outcome.text == request.text)
  }

  @Test("AI-04: 整形の同意のない送信先は飛ばす")
  func skipsDestinationWithoutConsent() async throws {
    let claude = StubAIProvider(behavior: .fail(.quotaExceeded), destination: .claude)
    let chatGPT = StubAIProvider(behavior: .echo, destination: .chatGPT)
    let router = try CloudFallbackRouter()

    let outcome = try await router.refine(
      request, consent: consent([.claude], fallback: true), primary: route(claude),
      fallbacks: [route(chatGPT)])

    #expect(await chatGPT.callCount == 0)
    #expect(outcome.fallbackReason == .providerFailed(.quotaExceeded))
  }

  @Test("AI-04: 同じ送信先へは再送せず、飛ばして次の送信先へ切り替える")
  func skipsSameDestinationAndContinues() async throws {
    let claude = StubAIProvider(behavior: .fail(.authenticationExpired), destination: .claude)
    let otherClaude = StubAIProvider(behavior: .echo, destination: .claude)
    let chatGPT = StubAIProvider(behavior: .echo, destination: .chatGPT)
    let router = try CloudFallbackRouter()

    let outcome = try await router.refine(
      request, consent: consent([.claude, .chatGPT], fallback: true), primary: route(claude),
      fallbacks: [route(otherClaude), route(chatGPT)])

    #expect(await otherClaude.callCount == 0)
    #expect(await chatGPT.callCount == 1)
    #expect(outcome.source == .cloud)
  }

  @Test("AI-04: 最初の送信先に同意がなければ、別の送信先の同意があっても切り替えない（AC-06）")
  func doesNotFallBackWhenPrimaryNotConsented() async throws {
    let claude = StubAIProvider(behavior: .echo, destination: .claude)
    let chatGPT = StubAIProvider(behavior: .echo, destination: .chatGPT)
    let router = try CloudFallbackRouter()

    let outcome = try await router.refine(
      request, consent: consent([.chatGPT], fallback: true), primary: route(claude),
      fallbacks: [route(chatGPT)])

    #expect(await claude.callCount == 0)
    #expect(await chatGPT.callCount == 0)
    #expect(outcome.fallbackReason == .consentNotGranted)
  }

  @Test("AC-06: Raw モードはどの送信先にも送信しない")
  func sendsNothingInRawMode() async throws {
    let claude = StubAIProvider(behavior: .echo, destination: .claude)
    let chatGPT = StubAIProvider(behavior: .echo, destination: .chatGPT)
    let router = try CloudFallbackRouter()
    let raw = RefinementRequest(text: request.text, mode: .raw)

    let outcome = try await router.refine(
      raw, consent: consent([.claude, .chatGPT], fallback: true), primary: route(claude),
      fallbacks: [route(chatGPT)])

    #expect(await claude.callCount == 0)
    #expect(await chatGPT.callCount == 0)
    #expect(outcome.source == .raw)
  }

  @Test("AC-16: すべての送信先で失敗したら、最後の失敗の理由でローカル結果に退避する")
  func fallsBackToLocalWhenAllFail() async throws {
    let claude = StubAIProvider(behavior: .fail(.authenticationExpired), destination: .claude)
    let chatGPT = StubAIProvider(behavior: .fail(.quotaExceeded), destination: .chatGPT)
    let router = try CloudFallbackRouter()

    let outcome = try await router.refine(
      request, consent: consent([.claude, .chatGPT], fallback: true), primary: route(claude),
      fallbacks: [route(chatGPT)])

    #expect(await claude.callCount == 1)
    #expect(await chatGPT.callCount == 1)
    #expect(
      outcome
        == RefinementOutcome(
          text: request.text, source: .localFallback(.providerFailed(.quotaExceeded))))
  }

  @Test("AI-04: 予算超過で送れなかった送信先の予算は使わず、切り替え先の予算で予約・確定する")
  func usesEachDestinationBudget() async throws {
    let claudeGuard = try makeGuard(spent: 90)
    let chatGPTGuard = try makeGuard()
    let claude = StubAIProvider(behavior: .echo, destination: .claude)
    let chatGPT = StubAIProvider(
      behavior: .respond(
        "明日の会議は10時からです。", usage: TokenUsage(inputTokens: 12, outputTokens: 8)),
      destination: .chatGPT)
    let router = try CloudFallbackRouter()

    let outcome = try await router.refine(
      request, consent: consent([.claude, .chatGPT], fallback: true),
      primary: route(claude, budget: budget(claudeGuard)),
      fallbacks: [route(chatGPT, budget: budget(chatGPTGuard))])

    #expect(await claude.callCount == 0)
    #expect(outcome.source == .cloud)
    #expect(await claudeGuard.ledger.spent(in: october) == 90)
    #expect(await chatGPTGuard.ledger.spent(in: october) == 20)
  }

  @Test("AI-04: 切り替え先の予算上限を超える見込みなら、切り替え先にも送信しない")
  func doesNotSendWhenFallbackBudgetExceeded() async throws {
    let claudeGuard = try makeGuard()
    let chatGPTGuard = try makeGuard(spent: 90)
    let claude = StubAIProvider(behavior: .fail(.authenticationExpired), destination: .claude)
    let chatGPT = StubAIProvider(behavior: .echo, destination: .chatGPT)
    let router = try CloudFallbackRouter()

    let outcome = try await router.refine(
      request, consent: consent([.claude, .chatGPT], fallback: true),
      primary: route(claude, budget: budget(claudeGuard)),
      fallbacks: [route(chatGPT, budget: budget(chatGPTGuard))])

    #expect(await chatGPT.callCount == 0)
    #expect(outcome.fallbackReason == .providerFailed(.budgetExceeded))
    // 認証失効は課金されないため、最初の送信先の予約は取り消されている
    #expect(await claudeGuard.ledger.spent(in: october) == 0)
    #expect(await chatGPTGuard.ledger.spent(in: october) == 90)
  }

  @Test("AC-16: 呼び出し元がキャンセルしたら、次の送信先へ送らず CancellationError を投げる", .timeLimit(.minutes(1)))
  func doesNotFallBackWhenCancelled() async throws {
    let claude = StubAIProvider(behavior: .echo, delay: .seconds(60), destination: .claude)
    let chatGPT = StubAIProvider(behavior: .echo, destination: .chatGPT)
    let router = try CloudFallbackRouter()
    let request = request
    let consent = consent([.claude, .chatGPT], fallback: true)
    let primary = route(claude)
    let fallbacks = [route(chatGPT)]
    let task = Task {
      try await router.refine(request, consent: consent, primary: primary, fallbacks: fallbacks)
    }
    while await claude.callCount == 0 {
      await Task.yield()
    }
    task.cancel()

    await #expect(throws: CancellationError.self) {
      try await task.value
    }
    #expect(await chatGPT.callCount == 0)
  }

  @Test("AI-04: 送信済みの送信先は、直前の送信先でなくても再送しない")
  func doesNotResendToAttemptedDestination() async throws {
    let claude = StubAIProvider(behavior: .fail(.authenticationExpired), destination: .claude)
    let chatGPT = StubAIProvider(behavior: .fail(.quotaExceeded), destination: .chatGPT)
    let otherClaude = StubAIProvider(behavior: .echo, destination: .claude)
    let router = try CloudFallbackRouter()

    let outcome = try await router.refine(
      request, consent: consent([.claude, .chatGPT], fallback: true), primary: route(claude),
      fallbacks: [route(chatGPT), route(otherClaude)])

    #expect(await chatGPT.callCount == 1)
    #expect(await otherClaude.callCount == 0)
    #expect(outcome.fallbackReason == .providerFailed(.quotaExceeded))
  }

  @Test("AC-16: 切り替え先で検証に失敗したら、使用量を含めてローカル結果に退避する")
  func keepsUsageWhenFallbackValidationFails() async throws {
    let usage = TokenUsage(inputTokens: 20, outputTokens: 0)
    let claude = StubAIProvider(behavior: .fail(.authenticationExpired), destination: .claude)
    let chatGPT = StubAIProvider(behavior: .respond("", usage: usage), destination: .chatGPT)
    let router = try CloudFallbackRouter()

    let outcome = try await router.refine(
      request, consent: consent([.claude, .chatGPT], fallback: true), primary: route(claude),
      fallbacks: [route(chatGPT)])

    #expect(
      outcome
        == RefinementOutcome(
          text: request.text, source: .localFallback(.validationFailed(.empty)), usage: usage))
  }

  @Test("AI-04: 自動フォールバックの同意を撤回していれば切り替えない")
  func doesNotFallBackWhenPermissionRevoked() async throws {
    let claude = StubAIProvider(behavior: .fail(.authenticationExpired), destination: .claude)
    let chatGPT = StubAIProvider(behavior: .echo, destination: .chatGPT)
    let router = try CloudFallbackRouter()
    var state = ConsentState()
    state.grant(.transmission(.textRefinement(.claude)))
    state.grant(.transmission(.textRefinement(.chatGPT)))
    state.grant(.crossProviderFallback)
    state.revoke(.crossProviderFallback)
    let revoked = state

    _ = try await router.refine(
      request, consent: { revoked }, primary: route(claude), fallbacks: [route(chatGPT)])

    #expect(await chatGPT.callCount == 0)
  }

  @Test(
    "AC-06: 最初の送信先の応答を待つ間に切り替え先への同意を撤回したら、切り替え先へ送らない",
    .timeLimit(.minutes(1)))
  func checksLatestConsentBeforeFallback() async throws {
    let claude = StubAIProvider(
      behavior: .fail(.authenticationExpired), delay: .seconds(1), destination: .claude)
    let chatGPT = StubAIProvider(behavior: .echo, destination: .chatGPT)
    let router = try CloudFallbackRouter()
    let granted = consent([.claude, .chatGPT], fallback: true)()
    let consent = MutableConsent(granted)
    let request = request
    let primary = route(claude)
    let fallbacks = [route(chatGPT)]
    let task = Task {
      try await router.refine(
        request, consent: { consent.state.withLock { $0 } }, primary: primary,
        fallbacks: fallbacks)
    }
    while await claude.callCount == 0 {
      await Task.yield()
    }
    consent.state.withLock { $0.revoke(.transmission(.textRefinement(.chatGPT))) }

    let outcome = try await task.value

    #expect(await chatGPT.callCount == 0)
    #expect(outcome.fallbackReason == .providerFailed(.authenticationExpired))
  }

  @Test("AI-04: 切り替え先がなければ、最初の送信先へ1回だけ送信する")
  func sendsOnceWithoutFallbacks() async throws {
    let claude = StubAIProvider(behavior: .fail(.authenticationExpired), destination: .claude)
    let router = try CloudFallbackRouter()

    let outcome = try await router.refine(
      request, consent: consent([.claude, .chatGPT], fallback: true), primary: route(claude),
      fallbacks: [])

    #expect(await claude.callCount == 1)
    #expect(outcome.fallbackReason == .providerFailed(.authenticationExpired))
  }

  @Test("AC-16: 切り替え先の応答を待つ間にキャンセルしたら CancellationError を投げる", .timeLimit(.minutes(1)))
  func throwsCancellationDuringFallback() async throws {
    let claude = StubAIProvider(behavior: .fail(.authenticationExpired), destination: .claude)
    let chatGPT = StubAIProvider(behavior: .echo, delay: .seconds(60), destination: .chatGPT)
    let router = try CloudFallbackRouter()
    let request = request
    let consent = consent([.claude, .chatGPT], fallback: true)
    let primary = route(claude)
    let fallbacks = [route(chatGPT)]
    let task = Task {
      try await router.refine(request, consent: consent, primary: primary, fallbacks: fallbacks)
    }
    while await chatGPT.callCount == 0 {
      await Task.yield()
    }
    task.cancel()

    await #expect(throws: CancellationError.self) {
      try await task.value
    }
  }

  @Test("AC-16: 上限時間が正でなければ作れない")
  func rejectsNonPositiveTimeout() {
    #expect(throws: RefinementRouterError.nonPositiveTimeout) {
      try CloudFallbackRouter(timeout: .zero)
    }
  }
}
