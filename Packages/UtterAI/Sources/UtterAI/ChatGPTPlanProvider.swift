import Foundation
import UtterCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// Sign in with ChatGPT（利用者の ChatGPT プラン）による Responses API の整形（AI-01, AI-02, AI-06, #50）。
///
/// macOS だけで使う（iOS は当面 OpenAI API キー方式のみ, #50 の判定）。既定では使われず、設定画面で選び、
/// 同意（AC-06）とサインインがそろったときだけ `RefinementRouter` から呼ばれる。
///
/// - 送信先は公開の Responses API（`POST https://api.openai.com/v1/responses`）に限る（S4）。
///   ChatGPT の `backend-api` や他製品のクライアントID は使わない（AI-02）
/// - `store: false`・`stream: true` で送り、整形指示は `instructions` に、発話はデータとして `input` に入れる（S4, S5, TXT-04）
/// - `temperature`・`max_output_tokens` など S5 が禁じる項目は送らない。出力の長さはクライアント側で
///   受信中の累計文字数で打ち切る（発話の文字数 × 4.1節の文字数比の上限。短い発話には下限）
/// - `response.completed` まで届いた応答だけを使う（S4）。途中で切れた・`response.incomplete`・拒否は使わない
/// - エラーは S7 の表に沿って `ChatGPTPlanFailure` に分け、AI-06 の分類へ対応づける。
///   利用上限・対象外のあとは `ChatGPTAccountSession` が送信を止める
/// - API キー方式や別のクラウドへ自動で切り替えない（AI-04, S7）。失敗時の Local Basic への退避は `RefinementRouter` が行う
/// - トークン課金ではない（利用者のプランの利用枠）ため、予算の確認は要らない（`isTokenBilled == false`, AI-05）
public struct ChatGPTPlanProvider: AIProvider {
  public struct Configuration: Hashable, Sendable {
    /// モデル名（AI-07, S4）。サインインしたアカウントのモデル一覧（`ChatGPTModelCatalog`）から利用者が選んだ値
    public var model: String
    /// HTTP の待ち時間の上限。整形全体の上限は `RefinementRouter.timeout` で別に設ける
    public var requestTimeout: Duration
    /// 1回の応答で受信する本文のバイト数の上限。超えたら残りを受信せずに打ち切る
    public var maxResponseBytes: Int
    /// 整形結果の文字数の上限を、発話の文字数の何倍にするか（4.1節の文字数比）
    public var outputLengthRatioLimit: Double
    /// 整形結果の文字数の上限の下限
    public var minimumOutputLengthLimit: Int
    /// ストリームが始まる前の一時的な障害（503, S7）で送り直す回数の上限
    public var unavailableRetryLimit: Int
    /// 送り直すまでの待ち時間
    public var unavailableRetryDelay: Duration

    /// - Throws: モデル名が空、上限・待ち時間が 0 以下、文字数比が有限の正の数でない、送り直しの回数が負の場合
    public init(
      model: String,
      requestTimeout: Duration = .seconds(30),
      maxResponseBytes: Int = OpenAIProvider.Configuration.defaultMaxResponseBytes,
      outputLengthRatioLimit: Double = OpenAIProvider.Configuration.defaultOutputLengthRatioLimit,
      minimumOutputLengthLimit: Int = OpenAIProvider.Configuration.defaultMinimumOutputLengthLimit,
      unavailableRetryLimit: Int = 1,
      unavailableRetryDelay: Duration = .milliseconds(500)
    ) throws(ChatGPTPlanProviderConfigurationError) {
      let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { throw .emptyModel }
      guard requestTimeout > .zero, maxResponseBytes > 0 else { throw .nonPositiveLimit }
      guard outputLengthRatioLimit.isFinite, outputLengthRatioLimit > 0,
        minimumOutputLengthLimit > 0
      else {
        throw .nonPositiveLimit
      }
      guard unavailableRetryLimit >= 0, unavailableRetryDelay >= .zero else {
        throw .negativeRetry
      }
      self.model = trimmed
      self.requestTimeout = requestTimeout
      self.maxResponseBytes = maxResponseBytes
      self.outputLengthRatioLimit = outputLengthRatioLimit
      self.minimumOutputLengthLimit = minimumOutputLengthLimit
      self.unavailableRetryLimit = unavailableRetryLimit
      self.unavailableRetryDelay = unavailableRetryDelay
    }

    /// `request` の整形結果として受け取る文字数の上限
    func outputLengthLimit(for request: RefinementRequest) -> Int {
      let scaled = (Double(request.text.count) * outputLengthRatioLimit).rounded(.up)
      return max(minimumOutputLengthLimit, scaled < Double(Int.max) ? Int(scaled) : .max)
    }
  }

  /// OpenAI の送信先。API キー方式と同じ事業者へ送るため、同じ送信先として同意を確かめる（AC-06）
  public var destination: CloudAIProviderKind { .chatGPT }
  /// 利用者の ChatGPT プランの利用枠で処理され、トークン課金ではない（S1）
  public var isTokenBilled: Bool { false }
  public let configuration: Configuration
  private let account: ChatGPTAccountSession
  private let transport: any HTTPStreamingTransport
  private let promptBuilder: RefinementPromptBuilder

  public init(
    account: ChatGPTAccountSession,
    configuration: Configuration,
    transport: any HTTPStreamingTransport = URLSessionStreamingTransport(),
    promptBuilder: RefinementPromptBuilder = RefinementPromptBuilder()
  ) {
    self.account = account
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
    let limit = configuration.outputLengthLimit(for: request)
    var retries = 0
    while true {
      if Task.isCancelled {
        throw .cancelled
      }
      let accessToken = try await account.accessToken()
      let urlRequest = try makeURLRequest(prompt, accessToken: accessToken)
      do throws(ChatGPTPlanFailure) {
        let response = try await send(urlRequest, over: transport, outputLengthLimit: limit)
        if Task.isCancelled {
          throw .transport(.cancelled)
        }
        return response
      } catch {
        await account.noteFailure(error)
        // ストリームが始まる前の一時的な障害だけ、回数を区切って送り直す（S7）
        guard case .temporarilyUnavailable(beforeStream: true) = error,
          retries < configuration.unavailableRetryLimit
        else {
          throw error.providerError
        }
        retries += 1
        do {
          try await Task.sleep(for: configuration.unavailableRetryDelay)
        } catch {
          throw .cancelled
        }
      }
    }
  }

  func makeURLRequest(
    _ prompt: RefinementPrompt, accessToken: String
  ) throws(AIProviderError) -> URLRequest {
    var request = URLRequest(url: ChatGPTSignIn.responsesEndpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = configuration.requestTimeout.timeInterval
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    request.setValue("text/event-stream", forHTTPHeaderField: "accept")
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "authorization")
    let body = PlanResponsesRequest(
      model: configuration.model,
      instructions: prompt.system,
      input: [.init(role: "user", content: prompt.user)],
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
  ) async throws(ChatGPTPlanFailure) -> RefinementResponse {
    let bytes: Transport.Bytes
    let response: HTTPURLResponse
    do {
      (bytes, response) = try await transport.bytes(for: request)
    } catch {
      throw .transport(Task.isCancelled ? .cancelled : AIProviderError(transportError: error))
    }
    var lines = LineReader(bytes.makeAsyncIterator(), byteLimit: configuration.maxResponseBytes)

    guard (200..<300).contains(response.statusCode) else {
      // 本文が上限を超えたり途中で切れたりしても、HTTP ステータスで分ける。
      // ストリームが始まる前の本文は `{"detail": "..."}` のこともあり、code がなくてもよい（S7）
      let body = try? await lines.readAll()
      let detail = body.flatMap { try? JSONDecoder().decode(ResponsesErrorResponse.self, from: $0) }
      throw ChatGPTPlanFailure.classify(
        status: response.statusCode, code: detail?.error.code ?? detail?.error.type)
    }
    let contentType = response.value(forHTTPHeaderField: "content-type")?.lowercased() ?? ""
    guard contentType.hasPrefix("text/event-stream") else {
      throw .transport(.invalidResponse)
    }

    var stream = PlanResponsesStream(outputLengthLimit: outputLengthLimit)
    while true {
      if Task.isCancelled {
        throw .transport(.cancelled)
      }
      let line: Data?
      do {
        line = try await lines.next()
      } catch {
        switch error {
        case .exceeded:
          // 受信量の上限を超えた。残りは受信しない
          throw .transport(.invalidResponse)
        case .transport(let error):
          throw .transport(Task.isCancelled ? .cancelled : AIProviderError(transportError: error))
        }
      }
      guard let line else {
        // `response.completed` が届く前に切れた。完了していない応答は使わない（S4）
        throw .transport(.networkUnavailable)
      }
      if let result = try stream.consume(line) {
        return result
      }
    }
  }
}

// MARK: - ストリームの解釈

/// Responses API のストリーム（Server-Sent Events）の `data:` 行を順に解釈する（S4）。
///
/// 受信中の累計文字数が上限を超えたら、そこで打ち切って空の応答を返し、呼び出し側の検証で退避させる
/// （`max_output_tokens` を送れないため, S5）。
struct PlanResponsesStream {
  let outputLengthLimit: Int
  private var text = ""
  private var outputLength = 0
  private var refused = false

  init(outputLengthLimit: Int) {
    self.outputLengthLimit = outputLengthLimit
  }

  /// 1行を解釈する。応答が決まったら返し、続きを読む必要があれば `nil` を返す。
  mutating func consume(_ line: Data) throws(ChatGPTPlanFailure) -> RefinementResponse? {
    let prefix = Data("data:".utf8)
    guard line.starts(with: prefix) else {
      return nil
    }
    let payload = line.dropFirst(prefix.count)
    // 種類だけを先に読み、扱うイベントのときだけ中身を読む
    guard let type = try? JSONDecoder().decode(StreamEvent.self, from: payload).type else {
      throw .transport(.invalidResponse)
    }
    switch type {
    case "response.output_text.delta":
      guard let delta = try? JSONDecoder().decode(TextDelta.self, from: payload).delta else {
        throw .transport(.invalidResponse)
      }
      outputLength += delta.count
      guard outputLength <= outputLengthLimit else {
        // 長すぎる応答は整形結果として使わない。残りは受信しない
        return RefinementResponse(text: "")
      }
      text += delta
      return nil
    case "response.refusal.delta":
      refused = true
      return nil
    case "response.completed":
      // 利用者のプランの利用枠のため、使用量は費用の推定に使わない（AI-05）
      return RefinementResponse(text: refused ? "" : text)
    case "response.incomplete":
      return RefinementResponse(text: "")
    case "response.failed":
      let code = (try? JSONDecoder().decode(ResponseEvent.self, from: payload))?.response.error?
        .code
      throw ChatGPTPlanFailure.classifyStreamFailure(code: code)
    case "error":
      let code = (try? JSONDecoder().decode(ErrorEvent.self, from: payload))?.code
      throw ChatGPTPlanFailure.classifyStreamFailure(code: code)
    default:
      // response.created・response.output_item.added などの途中経過
      return nil
    }
  }
}

// MARK: - エラーの分類（S7）

/// Sign in with ChatGPT の推論の失敗（S7 の表）。AI-06 の分類には `providerError` で対応づける。
public enum ChatGPTPlanFailure: Error, Hashable, Sendable {
  /// 401。利用者の認証を確認できない（`subscription_sharing_invalid_user` など）
  case invalidUser
  /// 403 `subscription_sharing_user_not_eligible`。利用者・ワークスペース・ポリシーの点で使えない
  case notEligible
  /// 403 で code がない（ストリームが始まる前の許可・地域などの制限, S7）
  case admissionRestricted
  /// 403 `subscription_sharing_route_not_supported`・`chatpass_v2_*`。ルートや許可の設定の誤り
  case misconfigured
  /// 429 `subscription_sharing_usage_limit_exceeded`。利用上限に到達した
  case usageLimitExceeded
  /// 503。一時的に確認できない。`beforeStream` はストリームが始まる前か（始まる前だけ送り直す）
  case temporarilyUnavailable(beforeStream: Bool)
  /// 400 `subscription_sharing_unsupported_capability`。非対応の入力・ツール・モデル
  case unsupportedCapability
  /// 送信・受信の失敗、ほかの HTTP ステータス、解釈できない応答
  case transport(AIProviderError)

  /// AI-06 の分類
  public var providerError: AIProviderError {
    switch self {
    case .invalidUser: .authenticationExpired
    case .notEligible, .admissionRestricted, .usageLimitExceeded: .quotaExceeded
    case .temporarilyUnavailable: .networkUnavailable
    case .misconfigured, .unsupportedCapability: .invalidResponse
    case .transport(let error): error
    }
  }

  /// ストリームが始まる前の HTTP ステータスと code（`error.code`、なければ `error.type`）を分ける
  static func classify(status: Int, code: String?) -> ChatGPTPlanFailure {
    if let known = classify(code: code, beforeStream: true) {
      return known
    }
    switch status {
    case 401: return .invalidUser
    case 403: return .admissionRestricted
    case 429: return .usageLimitExceeded
    case 503: return .temporarilyUnavailable(beforeStream: true)
    case 408, 504: return .transport(.timeout)
    case 500...: return .transport(.networkUnavailable)
    default: return .transport(.invalidResponse)
    }
  }

  /// ストリームの途中で届いた失敗（`response.failed`・`error`）の code を分ける（S4: 利用上限は途中で届くことがある）
  static func classifyStreamFailure(code: String?) -> ChatGPTPlanFailure {
    if let known = classify(code: code, beforeStream: false) {
      return known
    }
    return code == "server_error" ? .transport(.networkUnavailable) : .transport(.invalidResponse)
  }

  private static func classify(code: String?, beforeStream: Bool) -> ChatGPTPlanFailure? {
    guard let code else { return nil }
    if code.hasPrefix("chatpass_v2_") {
      return .misconfigured
    }
    switch code {
    case "subscription_sharing_invalid_user": return .invalidUser
    case "subscription_sharing_user_not_eligible": return .notEligible
    case "subscription_sharing_route_not_supported": return .misconfigured
    case "subscription_sharing_usage_limit_exceeded": return .usageLimitExceeded
    case "subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable":
      return .temporarilyUnavailable(beforeStream: beforeStream)
    case "subscription_sharing_unsupported_capability": return .unsupportedCapability
    default: return nil
    }
  }
}

/// `ChatGPTPlanProvider.Configuration` の不正な値。
public enum ChatGPTPlanProviderConfigurationError: Error, Hashable, Sendable {
  case emptyModel
  /// 上限・待ち時間・文字数比が正でない
  case nonPositiveLimit
  /// 送り直しの回数・待ち時間が負
  case negativeRetry
}

// アクセストークンをログに出さないよう、文字列表現とリフレクションにはモデル名だけを出す。
extension ChatGPTPlanProvider: CustomStringConvertible, CustomReflectable {
  public var description: String {
    "ChatGPTPlanProvider(model: \(configuration.model))"
  }

  public var customMirror: Mirror {
    Mirror(self, children: ["model": configuration.model])
  }
}

/// プラン利用の Responses API の本文（S4, S5）。`temperature`・`max_output_tokens` などは持たない
struct PlanResponsesRequest: Encodable {
  struct InputMessage: Encodable {
    let role: String
    let content: String
  }

  let model: String
  let instructions: String
  let input: [InputMessage]
  let store: Bool
  let stream: Bool
}

// MARK: - モデルの一覧（S4）

/// サインインしたアカウントで使えるモデル（S4）
public struct ChatGPTModel: Hashable, Sendable, Identifiable {
  /// `model` に送る値
  public let slug: String
  /// 画面に出す名前
  public let displayName: String

  public var id: String { slug }
}

/// サインインしたアカウントのモデルの一覧を読む（S4 の `GET /v1/models`）。
///
/// 推論と同じアクセストークンを使い、`visibility` が `list` のものだけを、サーバーの順のまま返す。
public struct ChatGPTModelCatalog: Sendable {
  private let account: ChatGPTAccountSession
  private let transport: any HTTPTransport

  public init(
    account: ChatGPTAccountSession,
    transport: any HTTPTransport = RedirectRefusingURLSessionTransport()
  ) {
    self.account = account
    self.transport = transport
  }

  public func models() async throws(AIProviderError) -> [ChatGPTModel] {
    let accessToken = try await account.accessToken()
    var request = URLRequest(url: ChatGPTSignIn.modelsEndpoint)
    request.httpMethod = "GET"
    request.timeoutInterval = 30
    request.setValue("application/json", forHTTPHeaderField: "accept")
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "authorization")
    let data: Data
    let response: HTTPURLResponse
    do {
      (data, response) = try await transport.send(request)
    } catch {
      throw Task.isCancelled ? .cancelled : AIProviderError(transportError: error)
    }
    guard response.statusCode == 200 else {
      let detail = try? JSONDecoder().decode(ResponsesErrorResponse.self, from: data)
      let failure = ChatGPTPlanFailure.classify(
        status: response.statusCode, code: detail?.error.code ?? detail?.error.type)
      throw failure.providerError
    }
    guard let list = try? JSONDecoder().decode(ModelList.self, from: data) else {
      throw .invalidResponse
    }
    return list.models.compactMap(\.value).compactMap { entry in
      guard entry.visibility == "list", !entry.slug.isEmpty else { return nil }
      return ChatGPTModel(slug: entry.slug, displayName: entry.displayName ?? entry.slug)
    }
  }

  private struct ModelList: Decodable {
    let models: [Lossy<Entry>]
  }

  private struct Entry: Decodable {
    let slug: String
    let displayName: String?
    let visibility: String?

    enum CodingKeys: String, CodingKey {
      case slug
      case displayName = "display_name"
      case visibility
    }
  }
}
