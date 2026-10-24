import Foundation
import UtterCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// Claude API（Anthropic Messages API）による整形（AI-01, AI-06, AI-07）。
///
/// - 1回の整形につき Messages API へ1回だけ送信し、再送しない
/// - API キーとモデル名は呼び出し側から受け取り、保存しない（Keychain・設定はアプリの責務）。
///   `APIKeyStore` を渡すと整形のたびに読み出すため、設定画面での保存・削除がすぐに反映される。
///   キーが未設定か読み出せないときは送信せず `authenticationExpired` を投げる（AC-12）
/// - 送信の同意は呼び出し側（`RefinementRouter`）で確認する（AC-06）
/// - プロンプトは `RefinementPromptBuilder` で組み立て、発話はデータとして渡す（TXT-04, CTX-03）
public struct ClaudeProvider: AIProvider {
  public static let defaultEndpoint = URL(string: "https://api.anthropic.com/v1/messages")!
  static let apiVersion = "2023-06-01"

  public struct Configuration: Hashable, Sendable {
    /// モデル名（AI-07）。設定値として受け取り、廃止・改名に追従できるようにする
    public var model: String
    /// 応答の最大トークン数
    public var maxTokens: Int
    /// `output_config.effort`。`nil` なら送らず、モデルの既定を使う
    public var effort: String?
    public var endpoint: URL
    /// HTTP の待ち時間の上限。整形全体の上限は `RefinementRouter.timeout` で別に設ける
    public var requestTimeout: Duration

    /// - Throws: モデル名が空、最大トークン数・待ち時間が 0 以下、エンドポイントが https でないか
    ///   Claude API のホストでない場合
    public init(
      model: String,
      maxTokens: Int = 4096,
      effort: String? = nil,
      endpoint: URL = ClaudeProvider.defaultEndpoint,
      requestTimeout: Duration = .seconds(30)
    ) throws(ClaudeProviderConfigurationError) {
      guard !model.isEmpty else { throw .emptyModel }
      guard maxTokens > 0 else { throw .nonPositiveMaxTokens }
      guard requestTimeout > .zero else { throw .nonPositiveRequestTimeout }
      // API キーを平文で送らない
      guard endpoint.scheme?.lowercased() == "https" else { throw .insecureEndpoint }
      // 同意は送信先（`destination`）ごとに確認するため、Claude 以外のホストへ発話と API キーを送らない（AC-06）
      guard endpoint.host?.lowercased() == ClaudeProvider.defaultEndpoint.host else {
        throw .unexpectedHost
      }
      self.model = model
      self.maxTokens = maxTokens
      self.effort = effort
      self.endpoint = endpoint
      self.requestTimeout = requestTimeout
    }
  }

  public var destination: CloudAIProviderKind { .claude }
  public let configuration: Configuration
  private let credential: Credential
  private let transport: any HTTPTransport
  private let promptBuilder: RefinementPromptBuilder

  public init(
    apiKey: String,
    configuration: Configuration,
    transport: any HTTPTransport = URLSessionTransport(),
    promptBuilder: RefinementPromptBuilder = RefinementPromptBuilder()
  ) {
    self.init(
      credential: .fixed(apiKey), configuration: configuration, transport: transport,
      promptBuilder: promptBuilder)
  }

  /// 整形のたびに `apiKeyStore` からキーを読み出す。
  public init(
    apiKeyStore: any APIKeyStore,
    configuration: Configuration,
    transport: any HTTPTransport = URLSessionTransport(),
    promptBuilder: RefinementPromptBuilder = RefinementPromptBuilder()
  ) {
    self.init(
      credential: .store(apiKeyStore), configuration: configuration, transport: transport,
      promptBuilder: promptBuilder)
  }

  private init(
    credential: Credential,
    configuration: Configuration,
    transport: any HTTPTransport,
    promptBuilder: RefinementPromptBuilder
  ) {
    self.credential = credential
    self.configuration = configuration
    self.transport = transport
    self.promptBuilder = promptBuilder
  }

  public func refine(_ request: RefinementRequest) async throws(AIProviderError)
    -> RefinementResponse
  {
    // Raw はプロンプトを組み立てず、送信もしない
    guard let prompt = promptBuilder.build(request) else {
      return RefinementResponse(text: request.text)
    }
    if Task.isCancelled {
      throw .cancelled
    }
    let urlRequest = try makeURLRequest(prompt, apiKey: try resolveAPIKey())

    let data: Data
    let response: HTTPURLResponse
    do {
      (data, response) = try await transport.send(urlRequest)
    } catch {
      if Task.isCancelled {
        throw .cancelled
      }
      throw Self.mapTransportError(error)
    }
    if Task.isCancelled {
      throw .cancelled
    }
    return try Self.parse(data, response: response)
  }

  /// 送信に使う API キー。未設定・読み出せないときは送信しない。
  private func resolveAPIKey() throws(AIProviderError) -> String {
    switch credential {
    case .fixed(let apiKey):
      return apiKey
    case .store(let store):
      // 保存先の失敗の詳細（状態コード）はここでは扱わない。設定画面で確かめる
      guard let key = try? store.load() else {
        throw .authenticationExpired
      }
      return key.value
    }
  }

  func makeURLRequest(_ prompt: RefinementPrompt, apiKey: String) throws(AIProviderError)
    -> URLRequest
  {
    var request = URLRequest(url: configuration.endpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = Self.seconds(configuration.requestTimeout)
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
    request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
    let body = MessagesRequest(
      model: configuration.model,
      maxTokens: configuration.maxTokens,
      system: prompt.system,
      messages: [.init(role: "user", content: prompt.user)],
      outputConfig: configuration.effort.map { .init(effort: $0) })
    guard let encoded = try? JSONEncoder().encode(body) else {
      throw .invalidResponse
    }
    request.httpBody = encoded
    return request
  }

  private static func seconds(_ duration: Duration) -> TimeInterval {
    let (seconds, attoseconds) = duration.components
    return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
  }
}

extension ClaudeProvider {
  /// API キーの受け取り方
  private enum Credential: Sendable {
    case fixed(String)
    case store(any APIKeyStore)
  }
}

// MARK: - 応答の解釈

extension ClaudeProvider {
  static func parse(_ data: Data, response: HTTPURLResponse) throws(AIProviderError)
    -> RefinementResponse
  {
    guard (200..<300).contains(response.statusCode) else {
      let type = try? JSONDecoder().decode(ErrorResponse.self, from: data).error.type
      throw mapStatus(response.statusCode, errorType: type)
    }
    guard let message = try? JSONDecoder().decode(MessagesResponse.self, from: data) else {
      throw .invalidResponse
    }
    let usage = TokenUsage(
      inputTokens: message.usage.inputTokens, outputTokens: message.usage.outputTokens)
    // 途中で打ち切られた応答（max_tokens）や拒否（refusal）などは整形結果として使わない。
    // 消費したトークンは費用の推定に残すため、使用量つきの空応答として返し、呼び出し側の検証で退避させる
    guard message.stopReason == "end_turn" || message.stopReason == "stop_sequence" else {
      return RefinementResponse(text: "", usage: usage)
    }
    let text = message.content.filter { $0.type == "text" }.compactMap(\.text).joined()
    return RefinementResponse(text: text, usage: usage)
  }

  /// HTTP ステータスとエラーの type を `AIProviderError` に対応づける（AI-06）。
  static func mapStatus(_ status: Int, errorType: String?) -> AIProviderError {
    switch (status, errorType) {
    case (401, _), (403, _), (_, "authentication_error"), (_, "permission_error"):
      .authenticationExpired
    case (402, _), (429, _), (_, "billing_error"), (_, "rate_limit_error"):
      .quotaExceeded
    case (408, _), (504, _):
      .timeout
    case (500..., _), (_, "api_error"), (_, "overloaded_error"):
      // サービス側の一時的な障害。届かないという点でネットワーク切断と同じ扱いにする
      .networkUnavailable
    default:
      // 400・404・413 など。リクエストやモデル名の設定の誤り
      .invalidResponse
    }
  }

  /// 送信部の失敗を `AIProviderError` に対応づける。
  static func mapTransportError(_ error: any Error) -> AIProviderError {
    if error is CancellationError {
      return .cancelled
    }
    guard let urlError = error as? URLError else {
      return .networkUnavailable
    }
    switch urlError.code {
    case .cancelled:
      return .cancelled
    case .timedOut:
      return .timeout
    case .badServerResponse, .cannotParseResponse, .cannotDecodeContentData,
      .cannotDecodeRawData:
      return .invalidResponse
    default:
      return .networkUnavailable
    }
  }
}

/// `ClaudeProvider.Configuration` の不正な値。
public enum ClaudeProviderConfigurationError: Error, Hashable, Sendable {
  case emptyModel
  case nonPositiveMaxTokens
  case nonPositiveRequestTimeout
  /// https 以外のエンドポイント
  case insecureEndpoint
  /// Claude API 以外のホストのエンドポイント
  case unexpectedHost
}

// API キーをログに出さないよう、文字列表現とリフレクションにはモデル名だけを出す。
extension ClaudeProvider: CustomStringConvertible, CustomReflectable {
  public var description: String {
    "ClaudeProvider(model: \(configuration.model))"
  }

  public var customMirror: Mirror {
    Mirror(self, children: ["model": configuration.model])
  }
}

// MARK: - Messages API の形式

struct MessagesRequest: Encodable {
  struct Message: Encodable {
    let role: String
    let content: String
  }

  struct OutputConfig: Encodable {
    let effort: String
  }

  let model: String
  let maxTokens: Int
  let system: String
  let messages: [Message]
  let outputConfig: OutputConfig?

  enum CodingKeys: String, CodingKey {
    case model
    case maxTokens = "max_tokens"
    case system
    case messages
    case outputConfig = "output_config"
  }
}

struct MessagesResponse: Decodable {
  struct Content: Decodable {
    let type: String
    let text: String?
  }

  struct Usage: Decodable {
    let inputTokens: Int
    let outputTokens: Int

    enum CodingKeys: String, CodingKey {
      case inputTokens = "input_tokens"
      case outputTokens = "output_tokens"
    }
  }

  let content: [Content]
  let stopReason: String?
  let usage: Usage

  enum CodingKeys: String, CodingKey {
    case content
    case stopReason = "stop_reason"
    case usage
  }
}

struct ErrorResponse: Decodable {
  struct Detail: Decodable {
    let type: String
  }

  let error: Detail
}
