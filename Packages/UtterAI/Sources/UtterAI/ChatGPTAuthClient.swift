import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// Sign in with ChatGPT の認証サーバーとのやりとり（S3, S6, S7）。本番は `OpenAIAuthClient`、
/// テストは `StubChatGPTAuthClient` を注入して実ネットワークに出ない。
///
/// 実装は認可コード・PKCE の検証子・トークン・クライアントID をログ・エラーに出さない。
public protocol ChatGPTAuthClient: Sendable {
  /// 認可コードをトークンに交換する（S3）
  func exchangeCode(
    _ exchange: ChatGPTCodeExchange
  ) async throws(ChatGPTSignInError) -> ChatGPTTokenResponse
  /// リフレッシュトークンで新しいトークンを得る（S6）。`scope` は送らず、付与済みの範囲を保つ
  func refresh(
    refreshToken: String, clientID: String
  ) async throws(ChatGPTSignInError) -> ChatGPTTokenResponse
  /// リフレッシュトークンを失効させる（S6 の End the renewable session）
  func revoke(refreshToken: String, clientID: String) async throws(ChatGPTSignInError)
  /// ID トークンの署名鍵（JWKS）を読む（S3）
  func signingKeys() async throws(ChatGPTSignInError) -> [ChatGPTSigningKey]
}

/// コード交換に送る値（S3）。値はログに出さない
public struct ChatGPTCodeExchange: Hashable, Sendable {
  public let code: String
  /// 発行済みのクライアントID（`dynamic_agent_client` ではない）
  public let clientID: String
  public let codeVerifier: String
  /// 認可要求と同じリダイレクト URI（ポートを含めて同じ値）
  public let redirectURI: URL
}

/// トークンエンドポイントの応答（S8）。値はログに出さない
public struct ChatGPTTokenResponse: Hashable, Sendable, Decodable {
  public let accessToken: String
  public let refreshToken: String?
  public let idToken: String?
  /// アクセストークンの有効秒数（S8 では 3600）
  public let expiresIn: Int?
  /// 付与されたスコープ（空白区切り）
  public let scope: String?

  public init(
    accessToken: String, refreshToken: String?, idToken: String?, expiresIn: Int?,
    scope: String?
  ) {
    self.accessToken = accessToken
    self.refreshToken = refreshToken
    self.idToken = idToken
    self.expiresIn = expiresIn
    self.scope = scope
  }

  /// 付与されたスコープの一覧
  var scopes: [String] {
    (scope ?? "").split(separator: " ").map(String.init)
  }

  enum CodingKeys: String, CodingKey {
    case accessToken = "access_token"
    case refreshToken = "refresh_token"
    case idToken = "id_token"
    case expiresIn = "expires_in"
    case scope
  }
}

extension ChatGPTCodeExchange: CustomStringConvertible, CustomReflectable {
  public var description: String { "ChatGPTCodeExchange(<redacted>)" }
  public var customMirror: Mirror { Mirror(self, children: []) }
}

extension ChatGPTTokenResponse: CustomStringConvertible, CustomReflectable {
  public var description: String {
    "ChatGPTTokenResponse(<redacted>, scopes: \(scopes.count))"
  }

  public var customMirror: Mirror { Mirror(self, children: ["scopes": scopes.count]) }
}

/// OpenAI の認証サーバー（`auth.openai.com`）とやりとりする `ChatGPTAuthClient`（S3, S6）。
///
/// - 送信先は `auth.openai.com` の https に限る。失効のエンドポイントは discovery 文書から読み、同じホストでなければ使わない
/// - 本文はフォーム形式（`application/x-www-form-urlencoded`）。クライアントシークレットは送らない（S3）
/// - リダイレクトには従わない（トークン・コードを別のホストへ送らない）
public struct OpenAIAuthClient: ChatGPTAuthClient {
  private let transport: any HTTPTransport
  private let requestTimeout: Duration

  public init(
    transport: any HTTPTransport = RedirectRefusingURLSessionTransport(),
    requestTimeout: Duration = .seconds(30)
  ) {
    self.transport = transport
    self.requestTimeout = requestTimeout
  }

  public func exchangeCode(
    _ exchange: ChatGPTCodeExchange
  ) async throws(ChatGPTSignInError) -> ChatGPTTokenResponse {
    let request = formRequest(
      ChatGPTSignIn.tokenEndpoint,
      [
        URLQueryItem(name: "grant_type", value: "authorization_code"),
        URLQueryItem(name: "client_id", value: exchange.clientID),
        URLQueryItem(name: "code", value: exchange.code),
        URLQueryItem(name: "code_verifier", value: exchange.codeVerifier),
        URLQueryItem(name: "redirect_uri", value: exchange.redirectURI.absoluteString),
        URLQueryItem(name: "resource", value: ChatGPTSignIn.resource),
      ])
    let (data, response) = try await send(request)
    guard response.statusCode == 200 else {
      throw Self.mapTokenError(status: response.statusCode, body: data, isRefresh: false)
    }
    return try Self.decodeTokens(data)
  }

  public func refresh(
    refreshToken: String, clientID: String
  ) async throws(ChatGPTSignInError) -> ChatGPTTokenResponse {
    let request = formRequest(
      ChatGPTSignIn.tokenEndpoint,
      [
        URLQueryItem(name: "grant_type", value: "refresh_token"),
        URLQueryItem(name: "client_id", value: clientID),
        URLQueryItem(name: "refresh_token", value: refreshToken),
        URLQueryItem(name: "resource", value: ChatGPTSignIn.resource),
      ])
    let (data, response) = try await send(request)
    guard response.statusCode == 200 else {
      throw Self.mapTokenError(status: response.statusCode, body: data, isRefresh: true)
    }
    return try Self.decodeTokens(data)
  }

  public func revoke(refreshToken: String, clientID: String) async throws(ChatGPTSignInError) {
    let endpoint = try await revocationEndpoint()
    let request = formRequest(
      endpoint,
      [
        URLQueryItem(name: "token", value: refreshToken),
        URLQueryItem(name: "token_type_hint", value: "refresh_token"),
        URLQueryItem(name: "client_id", value: clientID),
      ])
    let (_, response) = try await send(request)
    // 空の 200 が成功（失効済みのトークンでも 200, S6）
    switch response.statusCode {
    case 200: return
    case 500...: throw .networkUnavailable
    default: throw .rejected
    }
  }

  public func signingKeys() async throws(ChatGPTSignInError) -> [ChatGPTSigningKey] {
    let (data, response) = try await send(getRequest(ChatGPTSignIn.jwksEndpoint))
    guard response.statusCode == 200 else {
      throw response.statusCode >= 500 ? ChatGPTSignInError.networkUnavailable : .invalidResponse
    }
    guard let set = try? JSONDecoder().decode(JSONWebKeySet.self, from: data) else {
      throw .invalidResponse
    }
    return set.keys.compactMap(\.value)
  }

  /// discovery 文書の `revocation_endpoint`（S6）。`auth.openai.com` の https でなければ使わない
  private func revocationEndpoint() async throws(ChatGPTSignInError) -> URL {
    let (data, response) = try await send(getRequest(ChatGPTSignIn.discoveryEndpoint))
    guard response.statusCode == 200 else {
      throw response.statusCode >= 500 ? ChatGPTSignInError.networkUnavailable : .invalidResponse
    }
    guard let document = try? JSONDecoder().decode(DiscoveryDocument.self, from: data),
      let endpoint = URL(string: document.revocationEndpoint),
      endpoint.scheme?.lowercased() == "https",
      endpoint.host?.lowercased() == ChatGPTSignIn.authHost
    else {
      throw .invalidResponse
    }
    return endpoint
  }

  private func formRequest(_ url: URL, _ items: [URLQueryItem]) -> URLRequest {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = requestTimeout.timeInterval
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
    request.setValue("application/json", forHTTPHeaderField: "accept")
    request.httpBody = Data(formEncoded(items).utf8)
    return request
  }

  private func getRequest(_ url: URL) -> URLRequest {
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = requestTimeout.timeInterval
    request.setValue("application/json", forHTTPHeaderField: "accept")
    return request
  }

  private func send(
    _ request: URLRequest
  ) async throws(ChatGPTSignInError) -> (Data, HTTPURLResponse) {
    do {
      return try await transport.send(request)
    } catch {
      if Task.isCancelled || error is CancellationError {
        throw .cancelled
      }
      if let urlError = error as? URLError, urlError.code == .cancelled {
        throw .cancelled
      }
      throw .networkUnavailable
    }
  }

  static func decodeTokens(_ data: Data) throws(ChatGPTSignInError) -> ChatGPTTokenResponse {
    guard let tokens = try? JSONDecoder().decode(ChatGPTTokenResponse.self, from: data),
      !tokens.accessToken.isEmpty
    else {
      throw .invalidResponse
    }
    return tokens
  }

  /// リフレッシュトークンが使えないことを表す code（S7 の refresh errors）
  static let unusableRefreshTokenCodes: Set<String> = [
    "invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired",
    "refresh_token_invalidated", "refresh_token_reused",
  ]

  /// トークンエンドポイントのエラーを対応づける（S3, S7）。
  ///
  /// エラー本文の形は出典に書かれていないため、OAuth 2.0（RFC 6749 5.2節）の `{"error": "<code>"}` と、
  /// API の形の `{"error": {"code": "<code>"}}` の両方を読む（仮置き。実際の応答で確認する）
  static func mapTokenError(status: Int, body: Data, isRefresh: Bool) -> ChatGPTSignInError {
    let code = (try? JSONDecoder().decode(TokenErrorBody.self, from: body))?.code
    if let code {
      if isRefresh, unusableRefreshTokenCodes.contains(code) {
        return .refreshTokenUnusable
      }
      if !isRefresh, code == "invalid_grant" {
        return .invalidGrant
      }
      if code == "invalid_client" {
        return .invalidClient
      }
    }
    return status >= 500 ? .networkUnavailable : .rejected
  }
}

/// トークンエンドポイントのエラー本文。`error` が文字列でもオブジェクトでも code を読む（仮置き）
struct TokenErrorBody: Decodable {
  let code: String?

  private struct Nested: Decodable {
    let code: String?
  }

  private enum CodingKeys: String, CodingKey {
    case error
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if let code = try? container.decode(String.self, forKey: .error) {
      self.code = code
    } else {
      self.code = try container.decode(Nested.self, forKey: .error).code
    }
  }
}

/// discovery 文書のうち使う項目
struct DiscoveryDocument: Decodable {
  let revocationEndpoint: String

  enum CodingKeys: String, CodingKey {
    case revocationEndpoint = "revocation_endpoint"
  }
}

/// JWKS（RFC 7517）。読めない鍵だけを除く
struct JSONWebKeySet: Decodable {
  let keys: [Lossy<ChatGPTSigningKey>]
}

/// 要素ごとに読めなければ `nil` にする
struct Lossy<Value: Decodable>: Decodable {
  let value: Value?

  init(from decoder: any Decoder) throws {
    value = try? Value(from: decoder)
  }
}

/// ID トークンの署名鍵（RSA の JWK, RFC 7517・7518）
public struct ChatGPTSigningKey: Hashable, Sendable, Decodable {
  /// 鍵の種類。`RSA` だけを使う
  public let kty: String
  public let kid: String
  public let alg: String?
  public let use: String?
  /// RSA の modulus（base64url）
  public let n: String
  /// RSA の exponent（base64url）
  public let e: String

  public init(kty: String, kid: String, alg: String?, use: String?, n: String, e: String) {
    self.kty = kty
    self.kid = kid
    self.alg = alg
    self.use = use
    self.n = n
    self.e = e
  }
}

/// リダイレクトに従わない `URLSession` の送信部。トークン・認可コードを最初のホスト以外へ送らない（AI-02）。
/// 既定では Cookie・キャッシュをディスクに残さない ephemeral の構成を使う。3xx はそのまま返る
public struct RedirectRefusingURLSessionTransport: HTTPTransport {
  public let session: URLSession

  public init(session: URLSession = URLSession(configuration: .ephemeral)) {
    self.session = session
  }

  public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let (data, response) = try await session.data(for: request, delegate: RedirectRefusal())
    guard let response = response as? HTTPURLResponse else {
      throw URLError(.badServerResponse)
    }
    return (data, response)
  }
}

/// リダイレクトを断る delegate
final class RedirectRefusal: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
  ) async -> URLRequest? {
    nil
  }
}
