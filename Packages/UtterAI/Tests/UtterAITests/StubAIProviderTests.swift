import Testing

@testable import UtterAI

struct StubAIProviderTests {
  private let request = RefinementRequest(
    text: "えーと明日の会議は10時からです",
    mode: .natural,
    style: .polite,
    dictionaryTerms: ["Kubernetes"]
  )

  @Test("AI-06: 固定応答を返す")
  func returnsFixedResponse() async throws {
    let usage = TokenUsage(inputTokens: 12, outputTokens: 8)
    let stub = StubAIProvider(behavior: .respond("明日の会議は10時からです。", usage: usage))

    let response = try await stub.refine(request)

    #expect(response == RefinementResponse(text: "明日の会議は10時からです。", usage: usage))
  }

  @Test("AI-06: 空応答を返す")
  func returnsEmptyResponse() async throws {
    let stub = StubAIProvider(behavior: .respond(""))

    let response = try await stub.refine(request)

    #expect(response.text.isEmpty)
    #expect(response.usage == nil)
  }

  @Test("AI-06: 入力テキストをそのまま返す")
  func echoesInput() async throws {
    let stub = StubAIProvider(behavior: .echo)

    let response = try await stub.refine(request)

    #expect(response.text == request.text)
  }

  @Test("AI-06: 注入したエラーを種類ごとに投げる", arguments: AIProviderError.allCases)
  func throwsInjectedError(_ error: AIProviderError) async {
    let stub = StubAIProvider(behavior: .fail(error))

    await #expect(throws: error) {
      try await stub.refine(request)
    }
  }

  @Test("AI-06: 遅延のあとに応答する")
  func respondsAfterDelay() async throws {
    let delay = Duration.milliseconds(20)
    let stub = StubAIProvider(behavior: .echo, delay: delay)
    let clock = ContinuousClock()
    let start = clock.now

    let response = try await stub.refine(request)

    #expect(clock.now - start >= delay)
    #expect(response.text == request.text)
  }

  @Test("AI-06: 遅延中にキャンセルされたら cancelled を投げる")
  func throwsCancelledWhenCancelledDuringDelay() async throws {
    let stub = StubAIProvider(behavior: .echo, delay: .seconds(60))
    let request = request
    let task = Task {
      try await stub.refine(request)
    }
    while await stub.callCount == 0 {
      await Task.yield()
    }

    task.cancel()

    await #expect(throws: AIProviderError.cancelled) {
      try await task.value
    }
  }

  @Test("AI-06: 遅延なしでもキャンセル済みなら cancelled を投げる")
  func throwsCancelledWhenAlreadyCancelled() async {
    let stub = StubAIProvider(behavior: .echo)
    let request = request
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await stub.refine(request)
    }

    await #expect(throws: AIProviderError.cancelled) {
      try await task.value
    }
  }

  @Test("AI-06: 遅延中に振る舞いを変えても呼び出し時点の設定で応答する")
  func usesBehaviorAtCallTime() async throws {
    let stub = StubAIProvider(behavior: .respond("最初"), delay: .milliseconds(50))
    let request = request
    let task = Task {
      try await stub.refine(request)
    }
    while await stub.callCount == 0 {
      await Task.yield()
    }

    await stub.setBehavior(.fail(.timeout))
    let response = try await task.value

    #expect(response.text == "最初")
    await #expect(throws: AIProviderError.timeout) {
      try await stub.refine(request)
    }
  }

  @Test("CTX-03: 受け取った入力と呼び出し回数を記録する")
  func recordsReceivedRequests() async throws {
    let stub = StubAIProvider(behavior: .respond("整形済み"))
    let second = RefinementRequest(text: "git push して", mode: .raw, style: .command)
    #expect(await stub.callCount == 0)

    _ = try await stub.refine(request)
    await stub.setBehavior(.fail(.networkUnavailable))
    _ = try? await stub.refine(second)

    #expect(await stub.callCount == 2)
    #expect(await stub.receivedRequests == [request, second])
    let recorded = try #require(await stub.receivedRequests.first)
    #expect(recorded.text == request.text)
    #expect(recorded.mode == .natural)
    #expect(recorded.style == .polite)
    #expect(recorded.dictionaryTerms == ["Kubernetes"])
  }
}
