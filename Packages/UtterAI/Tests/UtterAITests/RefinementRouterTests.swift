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

  /// キャンセルに応じず、指定時間が過ぎるまで応答しないプロバイダー
  private struct UncooperativeProvider: AIProvider {
    let delay: Duration

    func refine(_ request: RefinementRequest) async throws(AIProviderError) -> RefinementResponse {
      let delay = delay
      await Task.detached {
        try? await Task.sleep(for: delay)
      }.value
      return RefinementResponse(text: request.text)
    }
  }

  @Test("AC-16: 検証を通った応答はクラウド整形の結果として返す")
  func returnsValidatedCloudResponse() async throws {
    let usage = TokenUsage(inputTokens: 20, outputTokens: 10)
    let stub = StubAIProvider(behavior: .respond("明日の会議は10時からです。", usage: usage))
    let router = try RefinementRouter(provider: stub)

    let outcome = try await router.refine(request, cloudConsentGranted: true)

    #expect(
      outcome == RefinementOutcome(text: "明日の会議は10時からです。", source: .cloud, usage: usage))
    #expect(outcome.fallbackReason == nil)
    #expect(await stub.receivedRequests == [request])
  }

  @Test("AC-16: 応答の前後の空白・改行を除いて返す")
  func trimsWhitespaceAroundResponse() async throws {
    let stub = StubAIProvider(behavior: .respond("\n 明日の会議は10時からです。\n\n"))
    let router = try RefinementRouter(provider: stub)

    let outcome = try await router.refine(request, cloudConsentGranted: true)

    #expect(outcome.text == "明日の会議は10時からです。")
    #expect(outcome.source == .cloud)
  }

  @Test("AC-06: Raw モードは送信せず STT テキストをそのまま返す")
  func skipsProviderInRawMode() async throws {
    let stub = StubAIProvider(behavior: .echo)
    let router = try RefinementRouter(
      provider: stub, localRefiner: FixedLocalRefiner(text: "ローカル整形"))
    let raw = RefinementRequest(text: "えーと明日の会議", mode: .raw)

    let outcome = try await router.refine(raw, cloudConsentGranted: true)

    #expect(await stub.callCount == 0)
    #expect(outcome == RefinementOutcome(text: "えーと明日の会議", source: .raw))
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
    arguments: AIProviderError.allCases.filter { $0 != .cancelled }
  )
  func fallsBackOnProviderFailure(_ error: AIProviderError) async throws {
    let stub = StubAIProvider(behavior: .fail(error))
    let router = try RefinementRouter(
      provider: stub, localRefiner: FixedLocalRefiner(text: "ローカル整形"))

    let outcome = try await router.refine(request, cloudConsentGranted: true)

    #expect(
      outcome
        == RefinementOutcome(text: "ローカル整形", source: .localFallback(.providerFailed(error))))
  }

  @Test("AC-16: 呼び出し元がキャンセルしていないのにプロバイダーが cancelled を返したら退避する")
  func fallsBackOnProviderCancelledWithoutCallerCancellation() async throws {
    let stub = StubAIProvider(behavior: .fail(.cancelled))
    let router = try RefinementRouter(provider: stub)

    let outcome = try await router.refine(request, cloudConsentGranted: true)

    #expect(
      outcome
        == RefinementOutcome(
          text: request.text, source: .localFallback(.providerFailed(.cancelled))))
  }

  @Test("AC-16: 検証失敗時はローカル結果に退避し、理由と使用量を含める")
  func fallsBackOnValidationFailure() async throws {
    let usage = TokenUsage(inputTokens: 20, outputTokens: 0)
    let stub = StubAIProvider(behavior: .respond("", usage: usage))
    let router = try RefinementRouter(provider: stub)

    let outcome = try await router.refine(request, cloudConsentGranted: true)

    #expect(outcome.text == request.text)
    #expect(outcome.fallbackReason == .validationFailed(.empty))
    #expect(outcome.usage == usage)
  }

  @Test("AC-17: 質問文への回答が返ったらローカル結果に退避する（TXT-04）")
  func fallsBackWhenQuestionAnswered() async throws {
    let question = RefinementRequest(text: "明日の天気はどうですか", mode: .natural)
    let stub = StubAIProvider(behavior: .respond("明日は晴れの予報です。"))
    let router = try RefinementRouter(provider: stub)

    let outcome = try await router.refine(question, cloudConsentGranted: true)

    #expect(outcome.text == question.text)
    #expect(outcome.fallbackReason == .validationFailed(.questionAnswered))
  }

  @Test("AC-16: 上限時間を超えたらタイムアウトとしてローカル結果に退避する", .timeLimit(.minutes(1)))
  func fallsBackOnTimeout() async throws {
    let stub = StubAIProvider(behavior: .echo, delay: .seconds(60))
    let router = try RefinementRouter(provider: stub, timeout: .milliseconds(50))
    let clock = ContinuousClock()
    let start = clock.now

    let outcome = try await router.refine(request, cloudConsentGranted: true)

    #expect(clock.now - start < .seconds(30))
    #expect(outcome.text == request.text)
    #expect(outcome.fallbackReason == .providerFailed(.timeout))
  }

  @Test("AC-16: キャンセルに応じないプロバイダーでも上限時間で退避する", .timeLimit(.minutes(1)))
  func fallsBackOnTimeoutWithUncooperativeProvider() async throws {
    let router = try RefinementRouter(
      provider: UncooperativeProvider(delay: .seconds(3)), timeout: .milliseconds(50))
    let clock = ContinuousClock()
    let start = clock.now

    let outcome = try await router.refine(request, cloudConsentGranted: true)

    #expect(clock.now - start < .seconds(2))
    #expect(outcome.fallbackReason == .providerFailed(.timeout))
  }

  @Test("AC-16: 上限時間内の遅延した応答は採用する")
  func acceptsDelayedResponseWithinTimeout() async throws {
    let stub = StubAIProvider(
      behavior: .respond("明日の会議は10時からです。"), delay: .milliseconds(20))
    let router = try RefinementRouter(provider: stub, timeout: .seconds(30))

    let outcome = try await router.refine(request, cloudConsentGranted: true)

    #expect(outcome.source == .cloud)
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

  @Test(
    "AC-16: キャンセルに応じないプロバイダーでも、呼び出し元のキャンセルで待たずに戻る", .timeLimit(.minutes(1)))
  func returnsOnCancellationWithUncooperativeProvider() async throws {
    let router = try RefinementRouter(
      provider: UncooperativeProvider(delay: .seconds(3)), timeout: .seconds(30))
    let request = request
    let clock = ContinuousClock()
    let start = clock.now
    let task = Task {
      try await router.refine(request, cloudConsentGranted: true)
    }
    try await Task.sleep(for: .milliseconds(20))

    task.cancel()

    await #expect(throws: CancellationError.self) {
      try await task.value
    }
    #expect(clock.now - start < .seconds(2))
  }

  @Test("AC-16: キャンセル済みなら同意の有無によらず送信も退避もしない", arguments: [true, false])
  func doesNotSendWhenAlreadyCancelled(_ consent: Bool) async throws {
    let stub = StubAIProvider(behavior: .echo)
    let router = try RefinementRouter(provider: stub)
    let request = request
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await router.refine(request, cloudConsentGranted: consent)
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
    let outcome = RefinementOutcome(
      text: "秘密の整形結果", source: .localFallback(.consentNotGranted),
      usage: TokenUsage(inputTokens: 1, outputTokens: 2))
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
