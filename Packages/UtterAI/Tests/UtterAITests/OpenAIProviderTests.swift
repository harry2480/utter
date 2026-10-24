import Foundation
import Synchronization
import Testing
import UtterCore

@testable import UtterAI

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

struct OpenAIProviderTests {
  /// 固定の応答を返し、受け取ったリクエストと読まれたバイト数を記録する送信部。実ネットワークに出ない
  final class StubTransport: HTTPStreamingTransport {
    enum Reply: Sendable {
      /// `body` を返す。`failure` を指定すると本文のあとで通信エラーにする
      case response(
        status: Int, body: String, contentType: String = "text/event-stream",
        failure: URLError.Code? = nil)
      /// 同じ本文を限りなく返し続ける
      case endless(String)
      case failure(URLError.Code)
      case cancellation
    }

    let reply: Reply
    let requests = Mutex<[URLRequest]>([])
    let bytesRead = Mutex(0)

    init(_ reply: Reply) {
      self.reply = reply
    }

    func bytes(for request: URLRequest) async throws -> (
      AsyncThrowingStream<UInt8, any Error>, HTTPURLResponse
    ) {
      requests.withLock { $0.append(request) }
      let source: [UInt8]
      let isEndless: Bool
      let failure: URLError.Code?
      let status: Int
      let contentType: String
      switch reply {
      case .response(let replyStatus, let body, let replyContentType, let replyFailure):
        (source, isEndless, failure) = (Array(body.utf8), false, replyFailure)
        (status, contentType) = (replyStatus, replyContentType)
      case .endless(let chunk):
        (source, isEndless, failure) = (Array(chunk.utf8), true, nil)
        (status, contentType) = (200, "text/event-stream")
      case .failure(let code):
        throw URLError(code)
      case .cancellation:
        throw CancellationError()
      }
      let response = HTTPURLResponse(
        url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": contentType])!
      let index = Counter()
      let stream = AsyncThrowingStream<UInt8, any Error> {
        let position = index.value.withLock { index in
          defer { index += 1 }
          return index
        }
        guard isEndless || position < source.count else {
          if let failure {
            throw URLError(failure)
          }
          return nil
        }
        self.bytesRead.withLock { $0 += 1 }
        return source[position % source.count]
      }
      return (stream, response)
    }
  }

  final class Counter: Sendable {
    let value = Mutex(0)
  }

  /// 送信に入ったことを知らせ、キャンセルされるまで本文を返さない送信部
  struct HangingTransport: HTTPStreamingTransport {
    let entered: AsyncStream<Void>.Continuation

    func bytes(for request: URLRequest) async throws -> (
      AsyncThrowingStream<UInt8, any Error>, HTTPURLResponse
    ) {
      let response = HTTPURLResponse(
        url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "text/event-stream"])!
      let entered = entered
      let stream = AsyncThrowingStream<UInt8, any Error> {
        entered.yield()
        let (never, _) = AsyncStream.makeStream(of: Void.self)
        for await _ in never {}
        throw CancellationError()
      }
      return (stream, response)
    }
  }

  /// キャンセルを無視して成功を返す送信部
  struct IgnoringCancellationTransport: HTTPStreamingTransport {
    func bytes(for request: URLRequest) async throws -> (
      AsyncThrowingStream<UInt8, any Error>, HTTPURLResponse
    ) {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await StubTransport(
        .response(status: 200, body: OpenAIProviderTests.successBody)
      ).bytes(for: request)
    }
  }

  static func events(_ lines: [String]) -> String {
    lines.map { line in
      let type =
        (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])?["type"]
        as? String ?? ""
      return "event: \(type)\ndata: \(line)\n\n"
    }.joined()
  }

  static let completed = #"""
    {"type":"response.completed","response":{"id":"resp_1","status":"completed","usage":{"input_tokens":120,"output_tokens":15,"total_tokens":135}}}
    """#

  static let successBody = events([
    #"{"type":"response.created","response":{"id":"resp_1","status":"in_progress"}}"#,
    #"{"type":"response.output_text.delta","item_id":"msg_1","output_index":0,"content_index":0,"delta":"明日の会議は"}"#,
    #"{"type":"response.output_text.delta","item_id":"msg_1","output_index":0,"content_index":0,"delta":"10時からです。"}"#,
    #"{"type":"response.output_text.done","item_id":"msg_1","output_index":0,"content_index":0,"text":"明日の会議は10時からです。"}"#,
    completed,
  ])

  private let request = RefinementRequest(
    text: "えーと明日の会議は10時からです", mode: .natural, style: .polite, dictionaryTerms: ["会議"])
  // swift-format-ignore: NeverUseForceTry
  private let configuration = try! OpenAIProvider.Configuration(
    model: "test-model", maxOutputTokens: 512)

  private func provider(
    _ transport: any HTTPStreamingTransport,
    apiKey: String = "sk-test-secret",
    configuration: OpenAIProvider.Configuration? = nil
  ) -> OpenAIProvider {
    OpenAIProvider(
      apiKey: apiKey, configuration: configuration ?? self.configuration, transport: transport,
      promptBuilder: RefinementPromptBuilder(makeNonce: { "n0nce" }))
  }

  @Test("AI-01: Responses API へ1回送信し、ストリームの整形結果と使用量を返す")
  func returnsTextAndUsage() async throws {
    let transport = StubTransport(.response(status: 200, body: Self.successBody))

    let response = try await provider(transport).refine(request)

    #expect(response.text == "明日の会議は10時からです。")
    #expect(response.usage == TokenUsage(inputTokens: 120, outputTokens: 15))
    #expect(transport.requests.withLock { $0.count } == 1)
  }

  @Test("AI-02: リクエストは設定のモデル名・API キーで、instructions と input を分けて組み立てる")
  func buildsRequest() async throws {
    let transport = StubTransport(.response(status: 200, body: Self.successBody))
    _ = try await provider(transport).refine(request)
    let sent = try #require(transport.requests.withLock { $0.first })

    #expect(sent.url == OpenAIProvider.defaultEndpoint)
    #expect(sent.url?.host == "api.openai.com")
    #expect(sent.httpMethod == "POST")
    #expect(sent.value(forHTTPHeaderField: "authorization") == "Bearer sk-test-secret")
    #expect(sent.value(forHTTPHeaderField: "content-type") == "application/json")
    #expect(sent.value(forHTTPHeaderField: "accept") == "text/event-stream")
    #expect(sent.timeoutInterval == 30)

    let body = try #require(sent.httpBody)
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let prompt = try #require(RefinementPromptBuilder(makeNonce: { "n0nce" }).build(request))
    #expect(json["model"] as? String == "test-model")
    #expect(json["instructions"] as? String == prompt.system)
    #expect(json["max_output_tokens"] as? Int == 512)
    #expect(json["store"] as? Bool == false)
    #expect(json["stream"] as? Bool == true)
    #expect(json["reasoning"] == nil)
    let input = try #require(json["input"] as? [[String: String]])
    #expect(input == [["role": "user", "content": prompt.user]])
    // 指示（system）を発話側に、発話を指示側に混ぜない（TXT-04）
    #expect(!prompt.system.contains("明日の会議"))
    // 文脈は送らない（CTX-03）。送るのは上の項目だけ
    #expect(
      Set(json.keys) == ["model", "instructions", "input", "max_output_tokens", "store", "stream"])
  }

  @Test("AI-07: reasoningEffort を設定すると reasoning.effort で送る")
  func sendsReasoningEffort() async throws {
    let transport = StubTransport(.response(status: 200, body: Self.successBody))
    _ = try await provider(transport, configuration: try .init(model: "m", reasoningEffort: "low"))
      .refine(request)

    let body = try #require(transport.requests.withLock { $0.first?.httpBody })
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect((json["reasoning"] as? [String: String]) == ["effort": "low"])
  }

  @Test("AI-01: Raw モードは送信せずにそのまま返す")
  func rawDoesNotSend() async throws {
    let transport = StubTransport(.response(status: 500, body: ""))

    let response = try await provider(transport).refine(RefinementRequest(text: "えー", mode: .raw))

    #expect(response.text == "えー")
    #expect(transport.requests.withLock { $0.isEmpty })
  }

  @Test(
    "AI-06: HTTP ステータスとエラーの code を AIProviderError に対応づける",
    arguments: [
      (401, "invalid_api_key", AIProviderError.authenticationExpired),
      (403, "unsupported_country_region_territory", .authenticationExpired),
      (429, "insufficient_quota", .quotaExceeded),
      (429, "rate_limit_exceeded", .quotaExceeded),
      (408, "timeout", .timeout),
      (504, "timeout", .timeout),
      (500, "server_error", .networkUnavailable),
      (503, "engine_overloaded", .networkUnavailable),
      (400, "invalid_request_error", .invalidResponse),
      (404, "model_not_found", .invalidResponse),
    ])
  func mapsErrorStatus(_ status: Int, _ code: String, _ expected: AIProviderError) async {
    let body =
      #"{"error":{"message":"本文 sk-test-secret","type":"x","param":null,"code":"\#(code)"}}"#
    let transport = StubTransport(
      .response(status: status, body: body, contentType: "application/json"))

    await #expect(throws: expected) {
      try await provider(transport).refine(request)
    }
  }

  @Test(
    "AI-06: ステータスと本文の code が食い違うときも対応づける",
    arguments: [
      (400, #"{"error":{"type":"insufficient_quota","code":null}}"#, AIProviderError.quotaExceeded),
      (
        400, #"{"error":{"type":"invalid_request_error","code":"invalid_api_key"}}"#,
        .authenticationExpired
      ),
      (429, "<html>", .quotaExceeded),
      (503, "<html>Service Unavailable</html>", .networkUnavailable),
      (418, "", .invalidResponse),
    ])
  func mapsMismatchedStatus(_ status: Int, _ body: String, _ expected: AIProviderError) async {
    await #expect(throws: expected) {
      try await provider(StubTransport(.response(status: status, body: body))).refine(request)
    }
  }

  @Test(
    "AI-05: ストリームの途中で届いた失敗は、課金されている可能性があるため予約を取り消さない分類にする",
    arguments: [
      (
        #"{"type":"response.failed","response":{"status":"failed","error":{"code":"rate_limit_exceeded","message":"x"}}}"#,
        AIProviderError.invalidResponse
      ),
      (
        #"{"type":"response.failed","response":{"status":"failed","error":{"code":"server_error","message":"x"}}}"#,
        .networkUnavailable
      ),
      (
        #"{"type":"response.failed","response":{"status":"failed","error":{"code":"invalid_prompt","message":"x"}}}"#,
        .invalidResponse
      ),
      (#"{"type":"response.failed","response":{"error":7}}"#, .invalidResponse),
      (
        #"{"type":"error","code":"insufficient_quota","message":"x","param":null}"#,
        .invalidResponse
      ),
      (#"{"type":"error","code":"invalid_api_key","message":"x"}"#, .invalidResponse),
      (#"{"type":"error","code":"server_error","message":"x"}"#, .networkUnavailable),
      (#"{"type":"error","code":null,"message":"x"}"#, .invalidResponse),
    ])
  func mapsStreamFailures(_ event: String, _ expected: AIProviderError) async {
    let body = Self.events([
      #"{"type":"response.output_text.delta","delta":"明日"}"#, event, Self.completed,
    ])

    await #expect(throws: expected) {
      try await provider(StubTransport(.response(status: 200, body: body))).refine(request)
    }
  }

  @Test("AI-01: 扱わない途中経過のイベントは、形が違っても読み飛ばす")
  func skipsUnknownEventsWithUnexpectedShape() async throws {
    let body = Self.events([
      #"{"type":"response.created","response":"x","delta":3,"code":[]}"#,
      #"{"type":"response.output_text.delta","delta":"完了"}"#,
      #"{"type":"response.output_text.done","text":{"a":1}}"#,
      Self.completed,
    ])

    let response = try await provider(StubTransport(.response(status: 200, body: body))).refine(
      request)

    #expect(response.text == "完了")
  }

  @Test("AI-05: 完了の使用量の形が読めなければ、使用量なしで返す")
  func completedWithUnreadableUsage() async throws {
    let body = Self.events([
      #"{"type":"response.output_text.delta","delta":"完了"}"#,
      #"{"type":"response.completed","response":{"usage":{"input_tokens":"x"}}}"#,
    ])

    let response = try await provider(StubTransport(.response(status: 200, body: body))).refine(
      request)

    #expect(response.text == "完了")
    #expect(response.usage == nil)
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
    "AI-06: 受信中の通信エラーを AIProviderError に対応づける",
    arguments: [
      (URLError.Code.networkConnectionLost, AIProviderError.networkUnavailable),
      (.timedOut, .timeout),
    ])
  func mapsErrorsWhileReceiving(_ code: URLError.Code, _ expected: AIProviderError) async {
    let body = Self.events([#"{"type":"response.output_text.delta","delta":"明日"}"#])

    await #expect(throws: expected) {
      try await provider(StubTransport(.response(status: 200, body: body, failure: code)))
        .refine(request)
    }
  }

  @Test("AI-06: 終わりの通知が届く前にストリームが切れたら使わない")
  func rejectsInterruptedStream() async {
    let body = Self.events([#"{"type":"response.output_text.delta","delta":"明日の会議は"}"#])

    await #expect(throws: AIProviderError.networkUnavailable) {
      try await provider(StubTransport(.response(status: 200, body: body))).refine(request)
    }
  }

  @Test(
    "AI-06: 解釈できない応答は invalidResponse にする",
    arguments: [
      (Self.events(["not json"]), "text/event-stream"),
      (Self.events([#"{"delta":"x"}"#]), "text/event-stream"),
      (#"{"output":[]}"#, "application/json"),
    ])
  func rejectsInvalidResponses(_ body: String, _ contentType: String) async {
    await #expect(throws: AIProviderError.invalidResponse) {
      try await provider(
        StubTransport(.response(status: 200, body: body, contentType: contentType))
      ).refine(request)
    }
  }

  @Test("AI-05: 打ち切られた応答（response.incomplete）は本文を使わず、使用量つきの空応答にする")
  func incompleteResponseKeepsUsage() async throws {
    let body = Self.events([
      #"{"type":"response.output_text.delta","delta":"途中まで"}"#,
      #"{"type":"response.incomplete","response":{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"usage":{"input_tokens":30,"output_tokens":512}}}"#,
    ])

    let response = try await provider(StubTransport(.response(status: 200, body: body))).refine(
      request)

    #expect(response.text.isEmpty)
    #expect(response.usage == TokenUsage(inputTokens: 30, outputTokens: 512))
  }

  @Test("TXT-04: 拒否（refusal）の応答は本文を使わず、使用量つきの空応答にする")
  func refusalIsNotUsed() async throws {
    let body = Self.events([
      #"{"type":"response.output_text.delta","delta":"明日"}"#,
      #"{"type":"response.refusal.delta","delta":"お答えできません"}"#,
      Self.completed,
    ])

    let response = try await provider(StubTransport(.response(status: 200, body: body))).refine(
      request)

    #expect(response.text.isEmpty)
    #expect(response.usage == TokenUsage(inputTokens: 120, outputTokens: 15))
  }

  @Test("4.1節: 整形結果が文字数の上限を超えたら、残りを受信せずに打ち切る")
  func stopsWhenOutputTooLong() async throws {
    let configuration = try OpenAIProvider.Configuration(
      model: "m", outputLengthRatioLimit: 2, minimumOutputLengthLimit: 10)
    // 発話 16 文字の2倍の 32 文字を超えるまで、同じ差分を返し続ける
    let delta = Self.events([#"{"type":"response.output_text.delta","delta":"あいうえお"}"#])
    let transport = StubTransport(.endless(delta))

    let response = try await provider(transport, configuration: configuration).refine(request)

    #expect(response.text.isEmpty)
    #expect(response.usage == nil)
    // 上限を超えた差分（7個目）の data 行までで読むのをやめる
    #expect(transport.bytesRead.withLock { $0 } == delta.utf8.count * 7 - 1)
  }

  @Test("4.1節: 文字数の上限ちょうどまでは使い、短い発話には下限を使う")
  func outputLengthLimit() throws {
    let configuration = try OpenAIProvider.Configuration(
      model: "m", outputLengthRatioLimit: 2.5, minimumOutputLengthLimit: 20)

    #expect(
      configuration.outputLengthLimit(
        for: RefinementRequest(text: String(repeating: "あ", count: 100), mode: .natural))
        == 250)
    #expect(
      configuration.outputLengthLimit(for: RefinementRequest(text: "えー", mode: .natural)) == 20)
  }

  @Test("4.1節: 受信量の上限を超えたら、残りを受信せずに invalidResponse にする")
  func stopsWhenResponseTooLarge() async throws {
    let configuration = try OpenAIProvider.Configuration(model: "m", maxResponseBytes: 1000)
    // 本文に入らない途中経過のイベントを返し続ける
    let transport = StubTransport(
      .endless(Self.events([#"{"type":"response.in_progress","response":{}}"#])))

    await #expect(throws: AIProviderError.invalidResponse) {
      try await provider(transport, configuration: configuration).refine(request)
    }
    #expect(transport.bytesRead.withLock { $0 } == 1001)
  }

  @Test("AI-06: エラー本文が受信量の上限を超えても、HTTP ステータスで対応づける")
  func mapsStatusWhenErrorBodyTooLarge() async throws {
    let configuration = try OpenAIProvider.Configuration(model: "m", maxResponseBytes: 10)
    let body = #"{"error":{"type":"x","code":"invalid_api_key"}}"#

    await #expect(throws: AIProviderError.quotaExceeded) {
      try await provider(
        StubTransport(.response(status: 429, body: body)), configuration: configuration
      ).refine(request)
    }
  }

  @Test("AI-01: CRLF の改行とコメント行を受け付ける")
  func acceptsCRLFAndComments() async throws {
    let body =
      ": keep-alive\r\n\r\nevent: response.output_text.delta\r\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"完了\"}\r\n\r\ndata: \(Self.completed)"

    let response = try await provider(StubTransport(.response(status: 200, body: body))).refine(
      request)

    #expect(response.text == "完了")
  }

  @Test(
    "AI-02: 不正な設定は作れない（送信先は OpenAI API のホストに限る）",
    arguments: [
      (
        "", 1, 1, 1, "https://api.openai.com/v1/responses",
        OpenAIProviderConfigurationError.emptyModel
      ),
      ("m", 0, 1, 1, "https://api.openai.com/v1/responses", .nonPositiveMaxOutputTokens),
      ("m", 1, 0, 1, "https://api.openai.com/v1/responses", .nonPositiveRequestTimeout),
      ("m", 1, 1, 0, "https://api.openai.com/v1/responses", .nonPositiveMaxResponseBytes),
      ("m", 1, 1, 1, "http://api.openai.com/v1/responses", .insecureEndpoint),
      ("m", 1, 1, 1, "https://example.com/v1/responses", .unexpectedHost),
      ("m", 1, 1, 1, "https://chatgpt.com/backend-api/responses", .unexpectedHost),
      ("m", 1, 1, 1, "https://api.openai.com.example.com/v1/responses", .unexpectedHost),
    ])
  func rejectsInvalidConfiguration(
    _ model: String, _ maxOutputTokens: Int, _ timeout: Int, _ maxResponseBytes: Int,
    _ endpoint: String, _ expected: OpenAIProviderConfigurationError
  ) throws {
    let url = try #require(URL(string: endpoint))
    #expect(throws: expected) {
      try OpenAIProvider.Configuration(
        model: model, maxOutputTokens: maxOutputTokens, endpoint: url,
        requestTimeout: .seconds(timeout), maxResponseBytes: maxResponseBytes)
    }
  }

  @Test(
    "4.1節: 文字数の上限の設定が不正なら作れない",
    arguments: [(0.0, 1), (-1, 1), (.infinity, 1), (.nan, 1), (2.5, 0)])
  func rejectsInvalidOutputLengthLimit(_ ratio: Double, _ minimum: Int) {
    #expect(throws: OpenAIProviderConfigurationError.invalidOutputLengthLimit) {
      try OpenAIProvider.Configuration(
        model: "m", outputLengthRatioLimit: ratio, minimumOutputLengthLimit: minimum)
    }
  }

  @Test("AI-06: 受信中にキャンセルされたら応答を待たずに cancelled を投げる", .timeLimit(.minutes(1)))
  func respondsToCancellation() async {
    let (entered, signal) = AsyncStream.makeStream(of: Void.self)
    let provider = provider(HangingTransport(entered: signal))
    let request = request
    let task = Task { () -> AIProviderError? in
      do throws(AIProviderError) {
        _ = try await provider.refine(request)
        return nil
      } catch {
        return error
      }
    }
    // 受信に入ってからキャンセルする
    var iterator = entered.makeAsyncIterator()
    await iterator.next()
    task.cancel()

    #expect(await task.value == .cancelled)
  }

  @Test("AI-06: 応答待ちが上限時間を超えたら RefinementRouter がタイムアウトとして退避する", .timeLimit(.minutes(1)))
  func routerTimesOut() async throws {
    let (_, signal) = AsyncStream.makeStream(of: Void.self)
    let router = try RefinementRouter(
      provider: provider(HangingTransport(entered: signal)), timeout: .milliseconds(50))

    let outcome = try await router.refine(
      request, consent: .refinementGranted(.chatGPT), budget: nil)

    #expect(outcome.source == .localFallback(.providerFailed(.timeout)))
  }

  @Test("AI-06: 送信部がキャンセルを無視して応答しても cancelled を投げる")
  func cancelledEvenIfTransportIgnoresCancellation() async {
    let provider = provider(IgnoringCancellationTransport())
    let request = request

    let error = await Task { () -> AIProviderError? in
      do throws(AIProviderError) {
        _ = try await provider.refine(request)
        return nil
      } catch {
        return error
      }
    }.value

    #expect(error == .cancelled)
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
    #expect(String(describing: provider) == "OpenAIProvider(model: test-model)")
  }

  @Test("AI-06: 送信するリクエストの文字列表現に API キーと発話を含めない")
  func redactsURLRequestDescription() async throws {
    let transport = StubTransport(.response(status: 200, body: Self.successBody))
    _ = try await provider(transport).refine(request)
    let sent = try #require(transport.requests.withLock { $0.first })

    for output in [String(describing: sent), String(reflecting: sent)] {
      #expect(!output.contains("sk-test-secret"))
      #expect(!output.contains("明日の会議"))
    }
  }

  @Test("AI-06: エラーは本文・API キーを持たない", arguments: [401, 429, 500, 400])
  func errorsHaveNoSecrets(_ status: Int) async {
    let body = #"{"error":{"type":"x","code":"x","message":"sk-test-secret 発話本文"}}"#
    do {
      _ = try await provider(StubTransport(.response(status: status, body: body))).refine(request)
      Issue.record("エラーになるはず")
    } catch {
      #expect(!String(reflecting: error).contains("sk-test-secret"))
      #expect(Mirror(reflecting: error).children.isEmpty)
    }
  }

  @Test("AC-16: 打ち切られた応答はローカル整形に退避し、使用量を残す")
  func incompleteResponseFallsBackWithUsage() async throws {
    let body = Self.events([
      #"{"type":"response.incomplete","response":{"status":"incomplete","usage":{"input_tokens":3,"output_tokens":5}}}"#
    ])
    let router = try RefinementRouter(
      provider: provider(StubTransport(.response(status: 200, body: body))))

    let outcome = try await router.refine(
      request, consent: .refinementGranted(.chatGPT), budget: nil)

    #expect(outcome.source == .localFallback(.validationFailed(.empty)))
    #expect(outcome.usage == TokenUsage(inputTokens: 3, outputTokens: 5))
  }

  @Test("AC-16: RefinementRouter の退避と組み合わせて使える")
  func worksWithRouter() async throws {
    let router = try RefinementRouter(
      provider: provider(StubTransport(.response(status: 200, body: Self.successBody))))

    let outcome = try await router.refine(
      request, consent: .refinementGranted(.chatGPT), budget: nil)

    #expect(outcome.source == .cloud)
    #expect(outcome.text == "明日の会議は10時からです。")
  }

  @Test("AC-06: 送信先は ChatGPT（OpenAI）と申告する（同意の確認に使う）")
  func declaresChatGPTDestination() {
    #expect(provider(StubTransport(.failure(.notConnectedToInternet))).destination == .chatGPT)
  }

  @Test(
    "AC-06: ChatGPT（OpenAI）への整形の同意がなければ RefinementRouter は送信しない",
    arguments: [
      ConsentState(), .refinementGranted(.claude),
      {
        var consent = ConsentState()
        consent.grant(.transmission(.editSelection(.chatGPT)))
        return consent
      }(),
      {
        var consent = ConsentState.refinementGranted(.chatGPT)
        consent.revoke(.transmission(.textRefinement(.chatGPT)))
        return consent
      }(),
    ])
  func noSendWithoutConsent(_ consent: ConsentState) async throws {
    let transport = StubTransport(.response(status: 200, body: Self.successBody))
    let router = try RefinementRouter(provider: provider(transport))

    let outcome = try await router.refine(request, consent: consent, budget: nil)

    #expect(outcome.source == .localFallback(.consentNotGranted))
    #expect(transport.requests.withLock { $0.isEmpty })
  }

  /// 1トークン 1 円の単価表と、上限 100 円の予算を持つ BudgetGuard
  private func makeGuard() throws -> BudgetGuard {
    let yen = try CostCurrency(code: "JPY")
    let estimator = CostEstimator(
      priceTable: try PriceTable(
        currency: yen, updatedOn: try CivilDate(year: 2026, month: 10, day: 1),
        prices: [
          try ModelPrice(
            model: "m", inputPerMillionTokens: Decimal(1_000_000),
            outputPerMillionTokens: Decimal(1_000_000))
        ]))
    return BudgetGuard(
      budget: try MonthlyBudget(limitAmount: Decimal(100), currency: yen), estimator: estimator,
      ledger: MonthlyUsageLedger(currency: yen))
  }

  @Test(
    "AI-05: 打ち切り・途中の失敗は見込み費用で、未完了の応答は実際の使用量で予算に記録する",
    arguments: [
      // 文字数の上限を超えて打ち切った（使用量は届かない）
      (
        StubTransport.Reply.endless(
          OpenAIProviderTests.events([
            #"{"type":"response.output_text.delta","delta":"あいうえおかきくけこ"}"#
          ])),
        30
      ),
      // 生成が始まったあとの利用枠の失敗
      (
        .response(
          status: 200,
          body: OpenAIProviderTests.events([
            #"{"type":"response.output_text.delta","delta":"明日"}"#,
            #"{"type":"response.failed","response":{"error":{"code":"rate_limit_exceeded"}}}"#,
          ])), 30
      ),
      // max_output_tokens などで未完了
      (
        .response(
          status: 200,
          body: OpenAIProviderTests.events([
            #"{"type":"response.incomplete","response":{"usage":{"input_tokens":3,"output_tokens":5}}}"#
          ])), 8
      ),
      // 送信前に拒否された（課金されない）
      (.response(status: 429, body: #"{"error":{"code":"rate_limit_exceeded"}}"#), 0),
    ])
  func recordsBudget(_ reply: StubTransport.Reply, _ expectedSpent: Int) async throws {
    let budgetGuard = try makeGuard()
    let october = try YearMonth(year: 2026, month: 10)
    let router = try RefinementRouter(provider: provider(StubTransport(reply)))

    let outcome = try await router.refine(
      request, consent: .refinementGranted(.chatGPT),
      budget: RefinementBudget(
        guard: budgetGuard, model: "m",
        expectedUsage: TokenUsage(inputTokens: 30, outputTokens: 0), month: october))

    #expect(outcome.source != .cloud)
    #expect(await budgetGuard.ledger.spent(in: october) == Decimal(expectedSpent))
  }
}
