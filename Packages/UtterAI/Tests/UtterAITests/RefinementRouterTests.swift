import Testing

@testable import UtterAI

struct RefinementRouterTests {
  private let request = RefinementRequest(
    text: "えーと明日の会議は10時からです", mode: .natural, style: .polite)

  /// 退避先として固定の本文を返すローカル整形
  private struct FixedLocalRefiner: LocalRefiner {
    let text: String

    func refine(_ request: RefinementRequest) -> String {
      text
    }
  }

  @Test("AC-16: 検証を通った応答はクラウド整形の結果として返す")
  func returnsValidatedCloudResponse() async throws {
    let usage = TokenUsage(inputTokens: 20, outputTokens: 10)
    let stub = StubAIProvider(behavior: .respond("明日の会議は10時からです。", usage: usage))
    let router = try RefinementRouter(provider: stub)

    let outcome = try await router.refine(request, cloudConsentGranted: true)

    #expect(outcome == RefinementOutcome(text: "明日の会議は10時からです。", source: .cloud(usage: usage)))
    #expect(outcome.fallbackReason == nil)
    #expect(await stub.receivedRequests == [request])
  }

  @Test("AC-06: 同意がオフのときはプロバイダーを呼ばずローカル結果を返す")
  func skipsProviderWithoutConsent() async throws {
    let stub = StubAIProvider(behavior: .echo)
    let router = try RefinementRouter(provider: stub)

    let outcome = try await router.refine(request, cloudConsentGranted: false)

    #expect(await stub.callCount == 0)
    #expect(
      outcome == RefinementOutcome(text: request.text, source: .localFallback(.consentNotGranted)))
  }

  @Test(
    "AC-16: プロバイダーの失敗時はローカル結果に退避し、理由を含める",
    arguments: AIProviderError.allCases
  )
  func fallsBackOnProviderFailure(_ error: AIProviderError) async throws {
    let stub = StubAIProvider(behavior: .fail(error))
    let router = try RefinementRouter(
      provider: stub, localRefiner: FixedLocalRefiner(text: "ローカル整形"))

    let outcome = try await router.refine(request, cloudConsentGranted: true)

    #expect(
      outcome == RefinementOutcome(text: "ローカル整形", source: .localFallback(.providerFailed(error))))
  }

  @Test("AC-16: 検証失敗時はローカル結果に退避し、理由を含める")
  func fallsBackOnValidationFailure() async throws {
    let stub = StubAIProvider(behavior: .respond(""))
    let router = try RefinementRouter(provider: stub)

    let outcome = try await router.refine(request, cloudConsentGranted: true)

    #expect(outcome.text == request.text)
    #expect(outcome.fallbackReason == .validationFailed(.empty))
  }

  @Test("AC-17: 質問文への回答が返ったらローカル結果に退避する（TXT-04）")
  func fallsBackWhenQuestionAnswered() async throws {
    let question = RefinementRequest(text: "明日の天気はどうですか", mode: .natural)
    let stub = StubAIProvider(behavior: .respond("明日は晴れの予報です。"))
    let router = try RefinementRouter(provider: stub)

    let outcome = try await router.refine(question, cloudConsentGranted: true)

    #expect(
      outcome
        == RefinementOutcome(
          text: question.text, source: .localFallback(.validationFailed(.questionAnswered))))
  }

  @Test("AC-16: 上限時間を超えたらタイムアウトとしてローカル結果に退避する", .timeLimit(.minutes(1)))
  func fallsBackOnTimeout() async throws {
    let stub = StubAIProvider(behavior: .echo, delay: .seconds(60))
    let router = try RefinementRouter(provider: stub, timeout: .milliseconds(50))
    let clock = ContinuousClock()
    let start = clock.now

    let outcome = try await router.refine(request, cloudConsentGranted: true)

    #expect(clock.now - start < .seconds(30))
    #expect(
      outcome
        == RefinementOutcome(text: request.text, source: .localFallback(.providerFailed(.timeout))))
  }

  @Test("AC-16: 上限時間内の遅延した応答は採用する")
  func acceptsDelayedResponseWithinTimeout() async throws {
    let stub = StubAIProvider(behavior: .respond("明日の会議は10時からです。"), delay: .milliseconds(20))
    let router = try RefinementRouter(provider: stub, timeout: .seconds(30))

    let outcome = try await router.refine(request, cloudConsentGranted: true)

    #expect(outcome.source == .cloud(usage: nil))
  }

  @Test(
    "AI-04: 失敗しても再送や別プロバイダーへの切り替えをせず、1回だけ送信する",
    arguments: [StubAIProvider.Behavior.fail(.networkUnavailable), .fail(.timeout), .respond("")]
  )
  func sendsOnlyOnce(_ behavior: StubAIProvider.Behavior) async throws {
    let stub = StubAIProvider(behavior: behavior)
    let router = try RefinementRouter(provider: stub)

    let outcome = try await router.refine(request, cloudConsentGranted: true)

    #expect(await stub.callCount == 1)
    #expect(outcome.fallbackReason != nil)
    #expect(outcome.text == request.text)
  }

  @Test("AC-16: 呼び出し元がキャンセルしたら退避せず CancellationError を投げる", .timeLimit(.minutes(1)))
  func throwsCancellationWhenCancelled() async throws {
    let stub = StubAIProvider(behavior: .echo, delay: .seconds(60))
    let router = try RefinementRouter(provider: stub)
    let request = request
    let task = Task {
      try await router.refine(request, cloudConsentGranted: true)
    }
    while await stub.callCount == 0 {
      await Task.yield()
    }

    task.cancel()

    await #expect(throws: CancellationError.self) {
      try await task.value
    }
  }

  @Test("AC-16: キャンセル済みなら送信しない")
  func doesNotSendWhenAlreadyCancelled() async throws {
    let stub = StubAIProvider(behavior: .echo)
    let router = try RefinementRouter(provider: stub)
    let request = request
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await router.refine(request, cloudConsentGranted: true)
    }

    await #expect(throws: CancellationError.self) {
      try await task.value
    }
    #expect(await stub.callCount == 0)
  }

  @Test("AC-16: 上限時間が0以下なら作成を拒否する", arguments: [Duration.zero, .seconds(-1)])
  func rejectsNonPositiveTimeout(_ timeout: Duration) {
    #expect(throws: RefinementRouterError.nonPositiveTimeout) {
      try RefinementRouter(provider: StubAIProvider(), timeout: timeout)
    }
  }

  @Test("AC-16: 既定の上限時間と Raw の退避先を持つ")
  func hasDefaults() throws {
    let router = try RefinementRouter(provider: StubAIProvider())

    #expect(router.timeout == RefinementRouter.defaultTimeout)
    #expect(router.localRefiner.refine(request) == request.text)
  }

  @Test("AC-16: 結果の文字列表現に本文を含めない")
  func redactsOutcomeText() {
    let outcome = RefinementOutcome(text: "秘密の整形結果", source: .localFallback(.consentNotGranted))
    let outputs = [
      String(describing: outcome),
      String(reflecting: outcome),
      String(describing: Mirror(reflecting: outcome).children.map(\.value)),
    ]

    for output in outputs {
      #expect(!output.contains("秘密の整形結果"))
    }
    #expect(String(describing: outcome).contains("length: 7"))
  }
}
