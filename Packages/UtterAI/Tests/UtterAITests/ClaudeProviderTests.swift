import Foundation
import Synchronization
import Testing

@testable import UtterAI

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

struct ClaudeProviderTests {
  /// 固定の応答を返し、受け取ったリクエストを記録する送信部。実ネットワークに出ない
  final class StubTransport: HTTPTransport {
    enum Reply: Sendable {
      case response(status: Int, body: String)
      case failure(URLError.Code)
      case cancellation
    }

    let reply: Reply
    let requests = Mutex<[URLRequest]>([])

    init(_ reply: Reply) {
      self.reply = reply
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
      requests.withLock { $0.append(request) }
      switch reply {
      case .response(let status, let body):
        let response = HTTPURLResponse(
          url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (Data(body.utf8), response)
      case .failure(let code):
        throw URLError(code)
      case .cancellation:
        throw CancellationError()
      }
    }
  }

  /// キャンセルされるまで応答しない送信部
  struct HangingTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
      try await Task.sleep(for: .seconds(3600))
      throw URLError(.timedOut)
    }
  }

  private static let successBody = """
    {"id":"msg_1","type":"message","role":"assistant","model":"m",
     "content":[{"type":"thinking","thinking":""},{"type":"text","text":"明日の会議は10時からです。"}],
     "stop_reason":"end_turn","usage":{"input_tokens":120,"output_tokens":15}}
    """

  private let request = RefinementRequest(
    text: "えーと明日の会議は10時からです", mode: .natural, style: .polite, dictionaryTerms: ["会議"])
  private let configuration = ClaudeProvider.Configuration(model: "test-model", maxTokens: 512)

  private func provider(_ transport: any HTTPTransport, apiKey: String = "sk-test-secret")
    -> ClaudeProvider
  {
    ClaudeProvider(
      apiKey: apiKey, configuration: configuration, transport: transport,
      promptBuilder: RefinementPromptBuilder(makeNonce: { "n0nce" }))
  }

  @Test("AI-01: Messages API へ1回送信し、整形結果と使用量を返す")
  func returnsTextAndUsage() async throws {
    let transport = StubTransport(.response(status: 200, body: Self.successBody))

    let response = try await provider(transport).refine(request)

    #expect(response.text == "明日の会議は10時からです。")
    #expect(response.usage == TokenUsage(inputTokens: 120, outputTokens: 15))
    #expect(transport.requests.withLock { $0.count } == 1)
  }

  @Test("AI-07: リクエストは設定のモデル名・API キー・API バージョンで組み立てる")
  func buildsRequest() async throws {
    let transport = StubTransport(.response(status: 200, body: Self.successBody))
    _ = try await provider(transport).refine(request)
    let sent = try #require(transport.requests.withLock { $0.first })

    #expect(sent.url == ClaudeProvider.defaultEndpoint)
    #expect(sent.httpMethod == "POST")
    #expect(sent.value(forHTTPHeaderField: "x-api-key") == "sk-test-secret")
    #expect(sent.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
    #expect(sent.value(forHTTPHeaderField: "content-type") == "application/json")
    #expect(sent.timeoutInterval == 30)

    let body = try #require(sent.httpBody)
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let prompt = try #require(
      RefinementPromptBuilder(makeNonce: { "n0nce" }).build(request))
    #expect(json["model"] as? String == "test-model")
    #expect(json["max_tokens"] as? Int == 512)
    #expect(json["system"] as? String == prompt.system)
    #expect(json["output_config"] == nil)
    let messages = try #require(json["messages"] as? [[String: String]])
    #expect(messages == [["role": "user", "content": prompt.user]])
  }

  @Test("AI-07: effort を設定すると output_config で送る")
  func sendsEffort() async throws {
    let transport = StubTransport(.response(status: 200, body: Self.successBody))
    let provider = ClaudeProvider(
      apiKey: "k", configuration: .init(model: "m", effort: "low"), transport: transport)

    _ = try await provider.refine(request)

    let body = try #require(transport.requests.withLock { $0.first?.httpBody })
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect((json["output_config"] as? [String: String]) == ["effort": "low"])
  }

  @Test("AI-01: Raw モードは送信せずにそのまま返す")
  func rawDoesNotSend() async throws {
    let transport = StubTransport(.response(status: 500, body: ""))

    let response = try await provider(transport).refine(RefinementRequest(text: "えー", mode: .raw))

    #expect(response.text == "えー")
    #expect(transport.requests.withLock { $0.isEmpty })
  }

  @Test(
    "AI-06: HTTP ステータスとエラー種別を AIProviderError に対応づける",
    arguments: [
      (401, "authentication_error", AIProviderError.authenticationExpired),
      (403, "permission_error", .authenticationExpired),
      (402, "billing_error", .quotaExceeded),
      (429, "rate_limit_error", .quotaExceeded),
      (408, "timeout_error", .timeout),
      (504, "timeout_error", .timeout),
      (500, "api_error", .networkUnavailable),
      (529, "overloaded_error", .networkUnavailable),
      (400, "invalid_request_error", .invalidResponse),
      (404, "not_found_error", .invalidResponse),
      (413, "request_too_large", .invalidResponse),
    ])
  func mapsErrorStatus(_ status: Int, _ type: String, _ expected: AIProviderError) async {
    let body = #"{"type":"error","error":{"type":"\#(type)","message":"本文 sk-test-secret"}}"#
    let transport = StubTransport(.response(status: status, body: body))

    await #expect(throws: expected) {
      try await provider(transport).refine(request)
    }
  }

  @Test("AI-06: エラー本文を解釈できなくても HTTP ステータスで対応づける")
  func mapsStatusWithoutBody() async {
    await #expect(throws: AIProviderError.quotaExceeded) {
      try await provider(StubTransport(.response(status: 429, body: "<html>"))).refine(request)
    }
  }

  @Test(
    "AI-06: 通信エラーを AIProviderError に対応づける",
    arguments: [
      (URLError.Code.timedOut, AIProviderError.timeout),
      (.notConnectedToInternet, .networkUnavailable),
      (.networkConnectionLost, .networkUnavailable),
      (.cannotFindHost, .networkUnavailable),
      (.cancelled, .cancelled),
      (.badServerResponse, .invalidResponse),
    ])
  func mapsTransportErrors(_ code: URLError.Code, _ expected: AIProviderError) async {
    await #expect(throws: expected) {
      try await provider(StubTransport(.failure(code))).refine(request)
    }
  }

  @Test("AI-06: 送信部の CancellationError は cancelled にする")
  func mapsCancellationError() async {
    await #expect(throws: AIProviderError.cancelled) {
      try await provider(StubTransport(.cancellation)).refine(request)
    }
  }

  @Test(
    "AI-06: 解釈できない応答・打ち切り・拒否は invalidResponse にする",
    arguments: [
      "not json",
      #"{"content":[],"usage":{"input_tokens":1}}"#,
      #"{"content":[{"type":"text","text":"途中"}],"stop_reason":"max_tokens","usage":{"input_tokens":1,"output_tokens":2}}"#,
      #"{"content":[],"stop_reason":"refusal","usage":{"input_tokens":1,"output_tokens":0}}"#,
    ])
  func rejectsInvalidResponses(_ body: String) async {
    await #expect(throws: AIProviderError.invalidResponse) {
      try await provider(StubTransport(.response(status: 200, body: body))).refine(request)
    }
  }

  @Test("AI-01: 複数のテキストブロックはつなげ、テキスト以外は除く")
  func joinsTextBlocks() async throws {
    let body = #"""
      {"content":[{"type":"text","text":"前半"},{"type":"thinking","thinking":"x"},{"type":"text","text":"後半"}],
       "stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":2}}
      """#

    let response = try await provider(StubTransport(.response(status: 200, body: body))).refine(
      request)

    #expect(response.text == "前半後半")
  }

  @Test("AI-06: キャンセルされたら応答を待たずに cancelled を投げる")
  func respondsToCancellation() async {
    let provider = provider(HangingTransport())
    let request = request
    let task = Task { () -> AIProviderError? in
      do throws(AIProviderError) {
        _ = try await provider.refine(request)
        return nil
      } catch {
        return error
      }
    }
    task.cancel()

    #expect(await task.value == .cancelled)
  }

  @Test("AI-06: キャンセル済みなら送信しない")
  func doesNotSendWhenAlreadyCancelled() async {
    let transport = StubTransport(.response(status: 200, body: Self.successBody))
    let provider = provider(transport)
    let request = request
    let task = Task { () -> AIProviderError? in
      withUnsafeCurrentTask { $0?.cancel() }
      do throws(AIProviderError) {
        _ = try await provider.refine(request)
        return nil
      } catch {
        return error
      }
    }

    #expect(await task.value == .cancelled)
    #expect(transport.requests.withLock { $0.isEmpty })
  }

  @Test("AI-06: 文字列表現に API キーを含めない")
  func redactsAPIKey() {
    let provider = provider(StubTransport(.failure(.timedOut)), apiKey: "sk-test-secret")
    let outputs = [
      String(describing: provider), String(reflecting: provider),
      String(describing: Mirror(reflecting: provider).children.map(\.value)),
    ]

    for output in outputs {
      #expect(!output.contains("sk-test-secret"))
    }
    #expect(String(describing: provider) == "ClaudeProvider(model: test-model)")
  }

  @Test("AI-06: エラーは本文・API キーを持たない", arguments: [401, 429, 500, 400])
  func errorsHaveNoSecrets(_ status: Int) async {
    let body = #"{"type":"error","error":{"type":"x","message":"sk-test-secret 発話本文"}}"#
    do {
      _ = try await provider(StubTransport(.response(status: status, body: body))).refine(request)
      Issue.record("エラーになるはず")
    } catch {
      #expect(!String(reflecting: error).contains("sk-test-secret"))
      #expect(Mirror(reflecting: error).children.isEmpty)
    }
  }

  @Test("AC-16: RefinementRouter の退避と組み合わせて使える")
  func worksWithRouter() async throws {
    let router = try RefinementRouter(
      provider: provider(StubTransport(.failure(.notConnectedToInternet))))

    let outcome = try await router.refine(request, cloudConsentGranted: true)

    #expect(outcome.source == .localFallback(.providerFailed(.networkUnavailable)))
  }

  @Test("AC-06: 同意がなければ RefinementRouter は送信しない")
  func noSendWithoutConsent() async throws {
    let transport = StubTransport(.response(status: 200, body: Self.successBody))
    let router = try RefinementRouter(provider: provider(transport))

    _ = try await router.refine(request, cloudConsentGranted: false)

    #expect(transport.requests.withLock { $0.isEmpty })
  }
}
