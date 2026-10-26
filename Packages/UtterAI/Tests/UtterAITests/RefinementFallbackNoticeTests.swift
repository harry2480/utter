import Testing
import UtterCore

@testable import UtterAI

/// 退避した理由から HUD の通知の種類を導く（4.1節, AC-16, AI-06）。
///
/// 通知の種類は関連値を持たない区分だけのため、発話本文・キー・トークンを含められない。
struct RefinementFallbackNoticeTests {
  private static let request = RefinementRequest(
    text: "えーと明日の会議は10時からです", mode: .natural, style: .polite)

  private static let reasons: [RefinementFallbackReason] =
    [.consentNotGranted, .sensitiveInputSuppressed]
    + AIProviderError.allCases.map(RefinementFallbackReason.providerFailed)
    + RefinementValidationFailure.allCases.map(RefinementFallbackReason.validationFailed)

  @Test("AC-16, AI-06: 退避の理由ごとに対応する通知の種類になる")
  func mapsEachReason() {
    #expect(RefinementFallbackNotice(reason: .consentNotGranted) == .consentNotGranted)
    #expect(RefinementFallbackNotice(reason: .sensitiveInputSuppressed) == .sensitiveInput)
    #expect(RefinementFallbackNotice(reason: .providerFailed(.timeout)) == .timeout)
    #expect(
      RefinementFallbackNotice(reason: .providerFailed(.authenticationExpired))
        == .authenticationExpired)
    #expect(RefinementFallbackNotice(reason: .providerFailed(.quotaExceeded)) == .quotaExceeded)
    #expect(RefinementFallbackNotice(reason: .providerFailed(.budgetExceeded)) == .budgetExceeded)
    #expect(
      RefinementFallbackNotice(reason: .providerFailed(.networkUnavailable)) == .networkUnavailable)
    #expect(
      RefinementFallbackNotice(reason: .providerFailed(.invalidResponse)) == .invalidResponse)
    #expect(RefinementFallbackNotice(reason: .providerFailed(.cancelled)) == .providerCancelled)
    for failure in RefinementValidationFailure.allCases {
      #expect(RefinementFallbackNotice(reason: .validationFailed(failure)) == .validationFailed)
    }
  }

  @Test("AI-06: プロバイダーの失敗の種類はすべて別の通知になり、同意なし・機密入力・検証失敗とも重ならない")
  func providerFailuresAreDistinct() {
    let providerNotices = AIProviderError.allCases.map {
      RefinementFallbackNotice(reason: .providerFailed($0))
    }
    #expect(Set(providerNotices).count == AIProviderError.allCases.count)
    #expect(
      Set(providerNotices).isDisjoint(with: [
        .consentNotGranted, .sensitiveInput, .validationFailed,
      ]))
  }

  @Test("AC-16: すべての通知の種類に、いずれかの退避の理由が対応する")
  func everyNoticeIsReachable() {
    let notices = Set(Self.reasons.map(RefinementFallbackNotice.init(reason:)))
    #expect(notices == Set(RefinementFallbackNotice.allCases))
  }

  @Test("AC-16: クラウド整形の結果と Raw モードでは退避の通知を出さない")
  func noNoticeWithoutFallback() {
    #expect(RefinementOutcome(text: "本文", source: .cloud).fallbackNotice == nil)
    #expect(RefinementOutcome(text: "本文", source: .raw).fallbackNotice == nil)
    #expect(
      RefinementOutcome(text: "本文", source: .localFallback(.providerFailed(.timeout)))
        .fallbackNotice == .timeout)
  }

  @Test("AC-16: 呼び出し元がキャンセルしたら結果を返さないため、退避の通知は出ない", .timeLimit(.minutes(1)))
  func noNoticeWhenCallerCancels() async throws {
    let stub = StubAIProvider(behavior: .echo, delay: .seconds(60))
    let router = try RefinementRouter(provider: stub)
    let task = Task { () async throws -> RefinementFallbackNotice? in
      try await router.refine(
        Self.request, consent: { .refinementGranted() }, budget: nil, sensitivity: { .allowedInput }
      ).fallbackNotice
    }
    while await stub.callCount == 0 {
      await Task.yield()
    }

    task.cancel()

    await #expect(throws: CancellationError.self) {
      try await task.value
    }
  }

  @Test(
    "AC-06, AC-12: 同意がなく機密入力でもあるときは、同意がないことを通知する",
    .timeLimit(.minutes(1)))
  func consentTakesPrecedenceOverSensitiveInput() async throws {
    let stub = StubAIProvider(behavior: .echo)
    let router = try RefinementRouter(provider: stub)

    let outcome = try await router.refine(
      Self.request, consent: { ConsentState() }, budget: nil, sensitivity: { .secureFieldInput })

    #expect(outcome.fallbackNotice == .consentNotGranted)
    #expect(await stub.callCount == 0)
  }
}
