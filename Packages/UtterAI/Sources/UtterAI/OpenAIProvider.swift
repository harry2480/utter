import Foundation
import UtterCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// OpenAI API キー方式の Responses API による整形（AI-01, AI-02, AI-06, AI-07）。
///
/// Sign in with ChatGPT の判定（#50）が不成立のときの代替（要件定義 11章）として先行実装する。
/// アプリからは組み立てておらず、既定では使われない。
///
/// - 1回の整形につき Responses API（`POST /v1/responses`）へ1回だけ送信し、再送しない
/// - 送信先は OpenAI API のホストに限る。他製品のクライアントID や非公開エンドポイントは使わない（AI-02）
/// - API キーとモデル名は呼び出し側から受け取り、保存しない（Keychain・設定はアプリの責務）
/// - 送信の同意は呼び出し側（`RefinementRouter`）で確認する。送信先は `.chatGPT`（OpenAI）として申告する（AC-06）
/// - プロンプトは `RefinementPromptBuilder` で組み立て、指示は `instructions` に、発話はデータとして `input` に入れる
///   （TXT-04, CTX-03）
/// - 応答はストリーム（`stream: true`）で受け取り、`response.completed` まで届いたものだけを整形結果にする。
///   受信量が上限を超えたら、残りを受信せずに打ち切る
/// - OpenAI 側に応答を保存させない（`store: false`）
public struct OpenAIProvider: AIProvider {
  public static let defaultEndpoint = URL(string: "https://api.openai.com/v1/responses")!

  public struct Configuration: Hashable, Sendable {
    /// モデル名（AI-07）。設定値として受け取り、廃止・改名に追従できるようにする
    public var model: String
    /// `max_output_tokens`。推論（reasoning）のトークンも含む
    public var maxOutputTokens: Int
    /// `reasoning.effort`。`nil` なら送らず、モデルの既定を使う
    public var reasoningEffort: String?
    public var endpoint: URL
    /// HTTP の待ち時間の上限。整形全体の上限は `RefinementRouter.timeout` で別に設ける
    public var requestTimeout: Duration
    /// 1回の応答で受信する本文のバイト数の上限。超えたら残りを受信せずに打ち切る
    public var maxResponseBytes: Int
    /// 整形結果の文字数の上限を、発話の文字数の何倍にするか。超えたら打ち切る（4.1節の文字数比）
    public var outputLengthRatioLimit: Double
    /// 整形結果の文字数の上限の下限。短い発話でも丁寧化などで長くなる分を許す
    public var minimumOutputLengthLimit: Int

    /// 受信する本文のバイト数の上限の既定値（暫定）
    public static let defaultMaxResponseBytes = 1 << 20
    /// 文字数比の上限の既定値（暫定）。応答検証の文字数比の上限（`RefinementValidationConfiguration`）にそろえる
    public static let defaultOutputLengthRatioLimit =
      RefinementValidationConfiguration.defaultLengthRatioRange.upperBound
    /// 文字数の上限の下限の既定値（暫定）
    public static let defaultMinimumOutputLengthLimit = 200

    /// - Throws: モデル名が空、上限・待ち時間が 0 以下、文字数比が有限の正の数でない、
    ///   エンドポイントが https でないか OpenAI API のホストでない場合
    public init(
      model: String,
      maxOutputTokens: Int = 4096,
      reasoningEffort: String? = nil,
      endpoint: URL = OpenAIProvider.defaultEndpoint,
      requestTimeout: Duration = .seconds(30),
      maxResponseBytes: Int = Configuration.defaultMaxResponseBytes,
      outputLengthRatioLimit: Double = Configuration.defaultOutputLengthRatioLimit,
      minimumOutputLengthLimit: Int = Configuration.defaultMinimumOutputLengthLimit
    ) throws(OpenAIProviderConfigurationError) {
      guard !model.isEmpty else { throw .emptyModel }
      guard maxOutputTokens > 0 else { throw .nonPositiveMaxOutputTokens }
      guard requestTimeout > .zero else { throw .nonPositiveRequestTimeout }
      guard maxResponseBytes > 0 else { throw .nonPositiveMaxResponseBytes }
      guard outputLengthRatioLimit.isFinite, outputLengthRatioLimit > 0,
        minimumOutputLengthLimit > 0
      else {
        throw .invalidOutputLengthLimit
      }
      // API キーを平文で送らない
      guard endpoint.scheme?.lowercased() == "https" else { throw .insecureEndpoint }
      // 同意は送信先（`destination`）ごとに確認するため、OpenAI API 以外のホストへ発話と API キーを送らない（AC-06, AI-02）
      guard endpoint.host?.lowercased() == OpenAIProvider.defaultEndpoint.host else {
        throw .unexpectedHost
      }
      self.model = model
      self.maxOutputTokens = maxOutputTokens
      self.reasoningEffort = reasoningEffort
      self.endpoint = endpoint
      self.requestTimeout = requestTimeout
      self.maxResponseBytes = maxResponseBytes
      self.outputLengthRatioLimit = outputLengthRatioLimit
      self.minimumOutputLengthLimit = minimumOutputLengthLimit
    }

    /// `request` の整形結果として受け取る文字数の上限
    func outputLengthLimit(for request: RefinementRequest) -> Int {
      let scaled = (Double(request.text.count) * outputLengthRatioLimit).rounded(.up)
      return max(minimumOutputLengthLimit, scaled < Double(Int.max) ? Int(scaled) : .max)
    }
  }

  /// OpenAI の送信先。Sign in with ChatGPT と同じ事業者へ送るため、同じ送信先として同意を確認する
  public var destination: CloudAIProviderKind { .chatGPT }
  /// API キー方式はトークン課金のため、予算上限を必ず確認する
  public var isTokenBilled: Bool { true }
  public let configuration: Configuration
  private let apiKey: String
  private let transport: any HTTPStreamingTransport
  private let promptBuilder: RefinementPromptBuilder

  public init(
    apiKey: String,
    configuration: Configuration,
    transport: any HTTPStreamingTransport = URLSessionStreamingTransport(),
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
    let urlRequest = try makeURLRequest(prompt)
    let result = try await send(
      urlRequest, over: transport,
      outputLengthLimit: configuration.outputLengthLimit(for: request))
    if Task.isCancelled {
      throw .cancelled
    }
    return result
  }

  func makeURLRequest(_ prompt: RefinementPrompt) throws(AIProviderError) -> URLRequest {
    var request = URLRequest(url: configuration.endpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = configuration.requestTimeout.timeInterval
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    request.setValue("text/event-stream", forHTTPHeaderField: "accept")
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")
    let body = ResponsesRequest(
      model: configuration.model,
      instructions: prompt.system,
      input: [.init(role: "user", content: prompt.user)],
      maxOutputTokens: configuration.maxOutputTokens,
      reasoning: configuration.reasoningEffort.map { .init(effort: $0) },
      store: false,
      stream: true)
    guard let encoded = try? JSONEncoder().encode(body) else {
      throw .invalidResponse
    }
    request.httpBody = encoded
    return request
  }

  /// 送信部の型を開いて送信し、ストリームを読む
  private func send<Transport: HTTPStreamingTransport>(
    _ request: URLRequest,
    over transport: Transport,
    outputLengthLimit: Int
  ) async throws(AIProviderError) -> RefinementResponse {
    let bytes: Transport.Bytes
    let response: HTTPURLResponse
    do {
      (bytes, response) = try await transport.bytes(for: request)
    } catch {
      if Task.isCancelled {
        throw .cancelled
      }
      throw AIProviderError(transportError: error)
    }
    var lines = LineReader(bytes.makeAsyncIterator(), byteLimit: configuration.maxResponseBytes)

    guard (200..<300).contains(response.statusCode) else {
      // エラー本文が上限を超えたり途中で切れたりしても、HTTP ステータスで対応づける
      let body = try? await lines.readAll()
      let code = body.flatMap { try? JSONDecoder().decode(ResponsesErrorResponse.self, from: $0) }?
        .error
      throw Self.mapStatus(response.statusCode, errorCode: code?.code ?? code?.type)
    }
    let contentType = response.value(forHTTPHeaderField: "content-type")?.lowercased() ?? ""
    guard contentType.hasPrefix("text/event-stream") else {
      throw .invalidResponse
    }

    var stream = ResponsesStream(outputLengthLimit: outputLengthLimit)
    while true {
      if Task.isCancelled {
        throw .cancelled
      }
      let line: Data?
      do {
        line = try await lines.next()
      } catch {
        switch error {
        case .exceeded:
          // 受信量の上限を超えた。残りは受信しない
          throw .invalidResponse
        case .transport(let error):
          if Task.isCancelled {
            throw .cancelled
          }
          throw AIProviderError(transportError: error)
        }
      }
      guard let line else {
        // `response.completed` などの終わりの通知が届く前に切れた
        throw .networkUnavailable
      }
      if let result = try stream.consume(line) {
        return result
      }
    }
  }
}

// MARK: - ストリームの解釈

extension OpenAIProvider {
  /// Responses API のストリーム（Server-Sent Events）の `data:` 行を順に解釈する。
  ///
  /// 各イベントは1行の `data:` に JSON で届く。`event:` 行・空行・コメントは読み飛ばす。
  struct ResponsesStream {
    let outputLengthLimit: Int
    private var text = ""
    private var outputLength = 0
    private var refused = false

    init(outputLengthLimit: Int) {
      self.outputLengthLimit = outputLengthLimit
    }

    /// 1行を解釈する。応答が決まったら返し、続きを読む必要があれば `nil` を返す。
    mutating func consume(_ line: Data) throws(AIProviderError) -> RefinementResponse? {
      let prefix = Data("data:".utf8)
      guard line.starts(with: prefix) else {
        return nil
      }
      let payload = line.dropFirst(prefix.count)
      // 種類だけを先に読み、扱うイベントのときだけ中身を読む。途中経過のイベントの形が変わっても失敗にしない
      guard let type = try? JSONDecoder().decode(StreamEvent.self, from: payload).type else {
        throw .invalidResponse
      }
      switch type {
      case "response.output_text.delta":
        let delta = try Self.decode(TextDelta.self, from: payload).delta
        // 区切りをまたぐ結合文字で多少ずれるが、上限の判定には足りる
        outputLength += delta.count
        guard outputLength <= outputLengthLimit else {
          // 長すぎる応答は整形結果として使わない。使用量は届かないため、見込み費用で記録させる（AI-05）
          return RefinementResponse(text: "")
        }
        text += delta
        return nil
      case "response.refusal.delta":
        refused = true
        return nil
      case "response.completed":
        // 使用量の形が読めなければ `nil` にし、見込み費用で記録させる（AI-05）
        let usage = (try? JSONDecoder().decode(ResponseEvent.self, from: payload))?.response.usage?
          .tokenUsage
        // 拒否は整形結果として使わない。使用量つきの空応答として返し、呼び出し側の検証で退避させる
        return RefinementResponse(text: refused ? "" : text, usage: usage)
      case "response.incomplete":
        // 途中で打ち切られた応答（max_output_tokens など）は使わない。消費したトークンは費用の推定に残す
        let usage = (try? JSONDecoder().decode(ResponseEvent.self, from: payload))?.response.usage?
          .tokenUsage
        return RefinementResponse(text: "", usage: usage)
      case "response.failed":
        let code = (try? JSONDecoder().decode(ResponseEvent.self, from: payload))?.response.error?
          .code
        throw OpenAIProvider.mapStreamErrorCode(code)
      case "error":
        let code = (try? JSONDecoder().decode(ErrorEvent.self, from: payload))?.code
        throw OpenAIProvider.mapStreamErrorCode(code)
      default:
        // response.created・response.output_item.added などの途中経過
        return nil
      }
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data)
      throws(AIProviderError) -> T
    {
      guard let value = try? JSONDecoder().decode(type, from: data) else {
        throw .invalidResponse
      }
      return value
    }
  }

  /// HTTP ステータスとエラーの code（なければ type）を `AIProviderError` に対応づける（AI-06）。
  static func mapStatus(_ status: Int, errorCode: String?) -> AIProviderError {
    switch (status, errorCode) {
    case (401, _), (403, _), (_, "invalid_api_key"):
      .authenticationExpired
    case (402, _), (429, _), (_, "insufficient_quota"), (_, "rate_limit_exceeded"):
      .quotaExceeded
    case (408, _), (504, _):
      .timeout
    case (500..., _), (_, "server_error"):
      // サービス側の一時的な障害。届かないという点でネットワーク切断と同じ扱いにする
      .networkUnavailable
    default:
      // 400・404 など。リクエストやモデル名の設定の誤り
      .invalidResponse
    }
  }

  /// ストリームの途中で届いた失敗（`response.failed`・`error`）の code を対応づける（AI-06）。
  ///
  /// 受け付けられて生成が始まったあとの失敗は課金されている可能性があるため、利用枠・認証の code でも
  /// `.quotaExceeded`・`.authenticationExpired` にしない。この2つは `RefinementRouter` が予算の予約を取り消すため、
  /// 使った分が予算から漏れる。見込み費用で記録される `.networkUnavailable`・`.invalidResponse` に寄せる（AI-04, AI-05）
  static func mapStreamErrorCode(_ code: String?) -> AIProviderError {
    switch code {
    case "server_error":
      .networkUnavailable
    default:
      .invalidResponse
    }
  }
}

/// 本文のバイト列を改行ごとに区切り、受信量の上限を超えたら読むのをやめる。
struct LineReader<Iterator: AsyncIteratorProtocol<UInt8, any Error>> {
  enum Failure: Error {
    /// 受信量の上限を超えた
    case exceeded
    case transport(any Error)
  }

  private var iterator: Iterator
  private let byteLimit: Int
  private var received = 0
  private var isFinished = false

  init(_ iterator: Iterator, byteLimit: Int) {
    self.iterator = iterator
    self.byteLimit = byteLimit
  }

  /// 次の1行（改行・末尾の CR を除く）。本文が終わったら `nil`
  mutating func next() async throws(Failure) -> Data? {
    guard !isFinished else {
      return nil
    }
    var line = Data()
    while true {
      let byte: UInt8?
      do {
        byte = try await iterator.next()
      } catch {
        throw .transport(error)
      }
      guard let byte else {
        isFinished = true
        return line.isEmpty ? nil : line
      }
      received += 1
      guard received <= byteLimit else {
        throw .exceeded
      }
      if byte == UInt8(ascii: "\n") {
        if line.last == UInt8(ascii: "\r") {
          line.removeLast()
        }
        return line
      }
      line.append(byte)
    }
  }

  /// 残りの本文をすべて読む
  mutating func readAll() async throws(Failure) -> Data {
    var body = Data()
    while let line = try await next() {
      body.append(line)
      body.append(UInt8(ascii: "\n"))
    }
    return body
  }
}

/// `OpenAIProvider.Configuration` の不正な値。
public enum OpenAIProviderConfigurationError: Error, Hashable, Sendable {
  case emptyModel
  case nonPositiveMaxOutputTokens
  case nonPositiveRequestTimeout
  case nonPositiveMaxResponseBytes
  /// 文字数比が有限の正の数でないか、文字数の上限の下限が 0 以下
  case invalidOutputLengthLimit
  /// https 以外のエンドポイント
  case insecureEndpoint
  /// OpenAI API 以外のホストのエンドポイント
  case unexpectedHost
}

// API キーをログに出さないよう、文字列表現とリフレクションにはモデル名だけを出す。
extension OpenAIProvider: CustomStringConvertible, CustomReflectable {
  public var description: String {
    "OpenAIProvider(model: \(configuration.model))"
  }

  public var customMirror: Mirror {
    Mirror(self, children: ["model": configuration.model])
  }
}

// MARK: - Responses API の形式

struct ResponsesRequest: Encodable {
  struct InputMessage: Encodable {
    let role: String
    let content: String
  }

  struct Reasoning: Encodable {
    let effort: String
  }

  let model: String
  let instructions: String
  let input: [InputMessage]
  let maxOutputTokens: Int
  let reasoning: Reasoning?
  let store: Bool
  let stream: Bool

  enum CodingKeys: String, CodingKey {
    case model
    case instructions
    case input
    case maxOutputTokens = "max_output_tokens"
    case reasoning
    case store
    case stream
  }
}

/// ストリームのイベントの種類
struct StreamEvent: Decodable {
  let type: String
}

/// `response.output_text.delta`
struct TextDelta: Decodable {
  let delta: String
}

/// `response.completed`・`response.incomplete`・`response.failed`
struct ResponseEvent: Decodable {
  struct Response: Decodable {
    let usage: Usage?
    let error: Failure?
  }

  struct Usage: Decodable {
    let inputTokens: Int
    let outputTokens: Int

    var tokenUsage: TokenUsage {
      TokenUsage(inputTokens: inputTokens, outputTokens: outputTokens)
    }

    enum CodingKeys: String, CodingKey {
      case inputTokens = "input_tokens"
      case outputTokens = "output_tokens"
    }
  }

  struct Failure: Decodable {
    let code: String?
  }

  let response: Response
}

/// `error`
struct ErrorEvent: Decodable {
  let code: String?
}

struct ResponsesErrorResponse: Decodable {
  struct Detail: Decodable {
    let type: String?
    let code: String?
  }

  let error: Detail
}
