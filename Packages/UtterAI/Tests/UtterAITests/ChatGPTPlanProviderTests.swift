import Foundation
import Testing
import UtterCore

@testable import UtterAI

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

struct ChatGPTPlanProviderTests {
  typealias StubTransport = OpenAIProviderTests.StubTransport

  private let request = RefinementRequest(
    text: "えーと明日の会議は10時からです", mode: .natural, style: .polite, dictionaryTerms: ["会議"])
  // swift-format-ignore: NeverUseForceTry
  private let configuration = try! ChatGPTPlanProvider.Configuration(model: "test-model")

  private func signedInSession(
    record: ChatGPTAccountRecord = ChatGPTTestSupport.signedInRecord()
  ) -> ChatGPTAccountSession {
    ChatGPTTestSupport.session(
      store: StubChatGPTAccountStore(record: record), authClient: StubChatGPTAuthClient())
  }

  private func provider(
    _ transport: StubTransport, session: ChatGPTAccountSession? = nil,
    configuration: ChatGPTPlanProvider.Configuration? = nil
  ) -> ChatGPTPlanProvider {
    ChatGPTPlanProvider(
      account: session ?? signedInSession(), configuration: configuration ?? self.configuration,
      transport: transport)
  }

  private func body(_ transport: StubTransport) throws -> [String: Any] {
    let request = try #require(transport.requests.withLock { $0.first })
    let data = try #require(request.httpBody)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  // MARK: - 送信内容（S4, S5）

  @Test("S4, S5: Responses API へ store:false・stream:true で送り、指示は instructions、発話は input に入れる")
  func requestShape() async throws {
    let transport = StubTransport(.response(status: 200, body: OpenAIProviderTests.successBody))
    let response = try await provider(transport).refine(request)
    #expect(response.text == "明日の会議は10時からです。")
    #expect(response.usage == nil)

    let sent = try #require(transport.requests.withLock { $0.first })
    #expect(sent.url == URL(string: "https://api.openai.com/v1/responses"))
    #expect(sent.httpMethod == "POST")
    #expect(sent.value(forHTTPHeaderField: "authorization") == "Bearer access-1")
    let json = try body(transport)
    #expect(json["model"] as? String == "test-model")
    #expect(json["store"] as? Bool == false)
    #expect(json["stream"] as? Bool == true)
    let instructions = try #require(json["instructions"] as? String)
    #expect(!instructions.contains("えーと明日の会議"))
    let input = try #require(json["input"] as? [[String: Any]])
    #expect(input.count == 1)
    #expect(input.first?["role"] as? String == "user")
    #expect((input.first?["content"] as? String)?.contains("えーと明日の会議は10時からです") == true)
  }

  @Test("S5: temperature・max_output_tokens など送ってはいけない項目を送らない")
  func forbiddenFieldsAreOmitted() async throws {
    let transport = StubTransport(.response(status: 200, body: OpenAIProviderTests.successBody))
    _ = try await provider(transport).refine(request)
    let json = try body(transport)
    #expect(Set(json.keys) == ["model", "instructions", "input", "store", "stream"])
    let forbidden = [
      "background", "conversation", "max_output_tokens", "max_tool_calls", "metadata",
      "moderation", "multi_agent", "prompt", "prompt_cache_retention", "safety_identifier",
      "temperature", "top_logprobs", "top_p", "truncation", "user", "previous_response_id",
    ]
    for key in forbidden {
      #expect(json[key] == nil)
    }
    let input = try #require(json["input"] as? [[String: Any]])
    #expect(!input.contains { $0["role"] as? String == "system" })
  }

  @Test("AI-04, AI-05: 送信先は OpenAI で、トークン課金ではない")
  func destinationAndBilling() {
    let provider = provider(StubTransport(.failure(.notConnectedToInternet)))
    #expect(provider.destination == .chatGPT)
    #expect(!provider.isTokenBilled)
    #expect(!"\(provider)".contains("access-1"))
  }

  @Test("TXT-01: Raw は送信しない")
  func rawIsNotSent() async throws {
    let transport = StubTransport(.response(status: 200, body: OpenAIProviderTests.successBody))
    let raw = RefinementRequest(text: "そのまま", mode: .raw)
    #expect(try await provider(transport).refine(raw).text == "そのまま")
    #expect(transport.requests.withLock { $0.isEmpty })
  }

  // MARK: - ストリーム（S4）

  @Test("S4: response.completed が届く前に切れた応答は使わない")
  func incompleteStreamIsNotUsed() async {
    let body = OpenAIProviderTests.events([
      #"{"type":"response.output_text.delta","delta":"途中まで"}"#
    ])
    let transport = StubTransport(.response(status: 200, body: body))
    await #expect(throws: AIProviderError.networkUnavailable) {
      try await provider(transport).refine(request)
    }
  }

  @Test("S5, 4.1節: 受信中の文字数が上限を超えたら、残りを受信せずに空の応答で打ち切る")
  func outputLengthLimit() async throws {
    let chunk = OpenAIProviderTests.events([
      #"{"type":"response.output_text.delta","delta":"ああああああああああ"}"#
    ])
    let transport = StubTransport(.endless(chunk))
    let configuration = try ChatGPTPlanProvider.Configuration(
      model: "test-model", outputLengthRatioLimit: 1, minimumOutputLengthLimit: 30)
    let response = try await provider(transport, configuration: configuration).refine(request)
    #expect(response.text == "")
    #expect(transport.bytesRead.withLock { $0 } < chunk.utf8.count * 10)
  }

  @Test("S4: response.incomplete と拒否は整形結果として使わない")
  func incompleteAndRefusal() async throws {
    let incomplete = OpenAIProviderTests.events([
      #"{"type":"response.output_text.delta","delta":"途中"}"#,
      #"{"type":"response.incomplete","response":{"status":"incomplete"}}"#,
    ])
    let refused = OpenAIProviderTests.events([
      #"{"type":"response.output_text.delta","delta":"x"}"#,
      #"{"type":"response.refusal.delta","delta":"できません"}"#,
      OpenAIProviderTests.completed,
    ])
    for body in [incomplete, refused] {
      let transport = StubTransport(.response(status: 200, body: body))
      #expect(try await provider(transport).refine(request).text == "")
    }
  }

  // MARK: - エラーの分類（S7, AI-06）

  @Test("S7, AI-06: ストリームが始まる前のエラーを表どおりに分ける")
  func errorTable() {
    let unavailable = ChatGPTPlanFailure.temporarilyUnavailable(beforeStream: true)
    let unsupported = "subscription_sharing_unsupported_capability"
    let cases: [(Int, String?, ChatGPTPlanFailure, AIProviderError)] = [
      (401, "subscription_sharing_invalid_user", .invalidUser, .authenticationExpired),
      (401, nil, .invalidUser, .authenticationExpired),
      (403, "subscription_sharing_user_not_eligible", .notEligible, .quotaExceeded),
      (403, "subscription_sharing_route_not_supported", .misconfigured, .invalidResponse),
      (403, "chatpass_v2_scope_not_authorized", .misconfigured, .invalidResponse),
      (403, "chatpass_v2_invalid_authorization_context", .misconfigured, .invalidResponse),
      (403, nil, .admissionRestricted, .quotaExceeded),
      (429, "subscription_sharing_usage_limit_exceeded", .usageLimitExceeded, .quotaExceeded),
      (503, "subscription_sharing_usage_unavailable", unavailable, .networkUnavailable),
      (503, "subscription_sharing_user_unavailable", unavailable, .networkUnavailable),
      (503, nil, unavailable, .networkUnavailable),
      (400, unsupported, .unsupportedCapability, .invalidResponse),
      (504, nil, .transport(.timeout), .timeout),
      (500, nil, .transport(.networkUnavailable), .networkUnavailable),
      (404, nil, .transport(.invalidResponse), .invalidResponse),
    ]
    for (status, code, failure, error) in cases {
      let classified = ChatGPTPlanFailure.classify(status: status, code: code)
      #expect(classified == failure)
      #expect(classified.providerError == error)
    }
  }

  @Test("S4, S7: ストリームの途中の利用上限・一時的な障害を分ける")
  func streamFailures() {
    #expect(
      ChatGPTPlanFailure.classifyStreamFailure(code: "subscription_sharing_usage_limit_exceeded")
        == .usageLimitExceeded)
    #expect(
      ChatGPTPlanFailure.classifyStreamFailure(code: "subscription_sharing_usage_unavailable")
        == .temporarilyUnavailable(beforeStream: false))
    #expect(ChatGPTPlanFailure.classifyStreamFailure(code: nil) == .transport(.invalidResponse))
  }

  @Test("S7: 利用上限に達したら、以降はプラン利用で送らない（再開するまで）")
  func usageLimitStopsSending() async throws {
    let limited = OpenAIProviderTests.events([
      #"{"type":"response.created","response":{"id":"resp_1","status":"in_progress"}}"#,
      #"{"type":"response.failed","response":{"status":"failed","error":{"code":"subscription_sharing_usage_limit_exceeded"}}}"#,
    ])
    let session = signedInSession()
    let transport = StubTransport(.response(status: 200, body: limited))
    let provider = provider(transport, session: session)
    await #expect(throws: AIProviderError.quotaExceeded) { try await provider.refine(request) }
    await #expect(throws: AIProviderError.quotaExceeded) { try await provider.refine(request) }
    #expect(transport.requests.withLock { $0.count } == 1)
    #expect(
      await session.status()
        == .signedIn(email: ChatGPTTestSupport.email, planUsage: .pausedForUsageLimit))
  }

  @Test("S7: ストリームが始まる前の 503 は回数を区切って送り直し、認証情報は残す")
  func unavailableIsRetriedOnce() async throws {
    let transport = StubTransport(
      .response(
        status: 503, body: #"{"detail":"unavailable"}"#, contentType: "application/json"))
    let configuration = try ChatGPTPlanProvider.Configuration(
      model: "test-model", unavailableRetryLimit: 1, unavailableRetryDelay: .zero)
    let session = signedInSession()
    await #expect(throws: AIProviderError.networkUnavailable) {
      try await provider(transport, session: session, configuration: configuration).refine(request)
    }
    #expect(transport.requests.withLock { $0.count } == 2)
    #expect(try await session.accessToken() == "access-1")
  }

  @Test("S3, S7: サインインしていない・プラン利用が許可されていなければ送らない")
  func notSignedInIsNotSent() async throws {
    var signedOut = ChatGPTTestSupport.signedInRecord()
    signedOut.tokens = nil
    for record in [signedOut, ChatGPTTestSupport.signedInRecord(planUsage: false)] {
      let transport = StubTransport(.response(status: 200, body: OpenAIProviderTests.successBody))
      let provider = provider(transport, session: signedInSession(record: record))
      await #expect(throws: AIProviderError.authenticationExpired) {
        try await provider.refine(request)
      }
      #expect(transport.requests.withLock { $0.isEmpty })
    }
  }

  // MARK: - 同意と退避（AC-06, 4.1節）

  @Test("AC-06: 同意がなければ RefinementRouter はプラン利用でも送らず、Local Basic に退避する")
  func consentIsRequired() async throws {
    let transport = StubTransport(.response(status: 200, body: OpenAIProviderTests.successBody))
    let router = try RefinementRouter(
      provider: provider(transport), localRefiner: LocalBasicRefiner())
    let outcome = try await router.refine(
      request, consent: { ConsentState() }, budget: nil, sensitivity: { .allowedInput })
    #expect(outcome.source == .localFallback(.consentNotGranted))
    #expect(transport.requests.withLock { $0.isEmpty })
  }

  @Test("4.1節, AI-04: 失敗したら別のクラウドへ切り替えず、Local Basic の結果に退避する")
  func failureFallsBackToLocalBasic() async throws {
    let transport = StubTransport(
      .response(
        status: 429, body: #"{"error":{"code":"subscription_sharing_usage_limit_exceeded"}}"#,
        contentType: "application/json"))
    let router = try RefinementRouter(
      provider: provider(transport), localRefiner: LocalBasicRefiner())
    let outcome = try await router.refine(
      request, consent: { .refinementGranted(.chatGPT) }, budget: nil,
      sensitivity: { .allowedInput })
    #expect(outcome.source == .localFallback(.providerFailed(.quotaExceeded)))
    #expect(outcome.text == LocalBasicRefiner().refine(request))
    #expect(transport.requests.withLock { $0.count } == 1)
  }
}
