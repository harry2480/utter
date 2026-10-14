import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// Claude API（Anthropic Messages API）による整形（AI-01, AI-06, AI-07）。
///
/// - 1回の整形につき Messages API へ1回だけ送信し、再送しない
/// - API キーとモデル名は呼び出し側から受け取り、保存しない（Keychain・設定はアプリの責務）
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

    public init(
      model: String,
      maxTokens: Int = 4096,
      effort: String? = nil,
      endpoint: URL = ClaudeProvider.defaultEndpoint,
      requestTimeout: Duration = .seconds(30)
    ) {
      self.model = model
      self.maxTokens = maxTokens
      self.effort = effort
      self.endpoint = endpoint
      self.requestTimeout = requestTimeout
    }
  }

  public let configuration: Configuration
  private let apiKey: String
  private let transport: any HTTPTransport
  private let promptBuilder: RefinementPromptBuilder

  public init(
    apiKey: String,
    configuration: Configuration,
    transport: any HTTPTransport = URLSession.shared,
    promptBuilder: RefinementPromptBuilder = RefinementPromptBuilder()
  ) {
    self.apiKey = apiKey
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
    let urlRequest = makeURLRequest(prompt)

    let data: Data
    let response: HTTPURLResponse
    do {
      (data, response) = try await transport.send(urlRequest)
    } catch {
      throw Self.mapTransportError(error)
    }
    if Task.isCancelled {
      throw .cancelled
    }
    return try Self.parse(data, response: response)
  }

  func makeURLRequest(_ prompt: RefinementPrompt) -> URLRequest {
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
    request.httpBody = try? JSONEncoder().encode(body)
    return request
  }

  private static func seconds(_ duration: Duration) -> TimeInterval {
    let (seconds, attoseconds) = duration.components
    return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
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
    // 途中で打ち切られた応答や拒否は整形結果として使わない
    guard message.stopReason == "end_turn" || message.stopReason == "stop_sequence" else {
      throw .invalidResponse
    }
    let text = message.content.filter { $0.type == "text" }.compactMap(\.text).joined()
    return RefinementResponse(
      text: text,
      usage: TokenUsage(
        inputTokens: message.usage.inputTokens, outputTokens: message.usage.outputTokens))
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
