import Foundation
import Synchronization

@testable import UtterAI

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// Sign in with ChatGPT のテストで使う値と Stub。実ネットワーク・ブラウザ・Keychain を使わない。
enum ChatGPTTestSupport {
  static let clientID = "oaiapp_test"
  static let subject = "user-subject"
  static let email = "user@example.com"
  /// プラン利用を含む、付与されたスコープ（空白区切り）
  static let planScope =
    "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
  /// 2026-10-27 00:00:00 UTC
  static let now = Date(timeIntervalSince1970: 1_793_059_200)

  /// 署名を確かめずに結果だけを決める検証器
  struct StubSignatureVerifier: RS256SignatureVerifying {
    let accepts: Bool

    func verify(signature: Data, of message: Data, with key: ChatGPTSigningKey) -> Bool {
      accepts
    }
  }

  static let signingKey = ChatGPTSigningKey(
    kty: "RSA", kid: "key-1", alg: "RS256", use: "sig", n: "AQAB", e: "AQAB")

  /// 署名を確かめない検証器
  static func validator(accepts: Bool = true) -> ChatGPTIDTokenValidator {
    ChatGPTIDTokenValidator(signatureVerifier: StubSignatureVerifier(accepts: accepts))
  }

  /// JWT の形の ID トークン。署名部は固定の値
  static func idToken(
    header: [String: Any] = ["alg": "RS256", "kid": "key-1", "typ": "JWT"],
    claims: [String: Any]
  ) -> String {
    func encode(_ object: [String: Any]) -> String {
      // swift-format-ignore: NeverUseForceTry
      base64URLEncoded(try! JSONSerialization.data(withJSONObject: object))
    }
    return "\(encode(header)).\(encode(claims)).\(base64URLEncoded(Data("signature".utf8)))"
  }

  /// 検証を通るクレーム
  static func claims(
    nonce: String, audience: Any = [clientID], subject: String = ChatGPTTestSupport.subject,
    expiresAt: Date = ChatGPTTestSupport.now.addingTimeInterval(3600)
  ) -> [String: Any] {
    [
      "iss": "https://auth.openai.com", "sub": subject, "aud": audience,
      "exp": expiresAt.timeIntervalSince1970, "iat": now.timeIntervalSince1970,
      "nonce": nonce, "email": email,
    ]
  }

  /// プラン利用のスコープを含むトークンの応答
  static func tokenResponse(
    access: String = "access-1", refresh: String? = "refresh-1", idToken: String? = "id",
    expiresIn: Int? = 3600,
    scope: String? = planScope
  ) -> ChatGPTTokenResponse {
    ChatGPTTokenResponse(
      accessToken: access, refreshToken: refresh, idToken: idToken, expiresIn: expiresIn,
      scope: scope)
  }

  /// サインイン済みの記録
  static func signedInRecord(
    access: String = "access-1", refresh: String = "refresh-1",
    expiresAt: Date = now.addingTimeInterval(3600), planUsage: Bool = true
  ) -> ChatGPTAccountRecord {
    var scopes = ["openid", "profile", "email", "offline_access", "resource.invoke"]
    if planUsage {
      scopes.append("chatgpt.tokens.use.direct")
    }
    return ChatGPTAccountRecord(
      hostID: ChatGPTHostID(rawValue: "urn:uuid:00000000-0000-4000-8000-000000000000"),
      registration: ChatGPTRegistration(clientID: clientID, subject: subject, email: email),
      tokens: ChatGPTTokens(
        accessToken: access, refreshToken: refresh, idToken: "previous-id-token",
        expiresAt: expiresAt, scopes: scopes))
  }

  static func session(
    store: StubChatGPTAccountStore, authClient: StubChatGPTAuthClient,
    validator: ChatGPTIDTokenValidator = validator(),
    signInTimeout: Duration = .seconds(5)
  ) -> ChatGPTAccountSession {
    ChatGPTAccountSession(
      store: store, authClient: authClient, validator: validator,
      signInTimeout: signInTimeout, now: { now })
  }

  /// 認可要求の URL のクエリ
  static func query(_ url: URL) -> [String: String] {
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    var result: [String: String] = [:]
    for item in items {
      result[item.name] = item.value ?? ""
    }
    return result
  }
}

/// 決めた応答を返し、受け取ったリクエストを記録する `HTTPTransport`。実ネットワークに出ない
final class StubHTTPTransport: HTTPTransport {
  struct Reply: Sendable {
    let status: Int
    let body: String
  }

  private let replies: @Sendable (URLRequest) -> Reply
  private let received = Mutex<[URLRequest]>([])

  init(_ replies: @escaping @Sendable (URLRequest) -> Reply) {
    self.replies = replies
  }

  var requests: [URLRequest] { received.withLock { $0 } }

  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    received.withLock { $0.append(request) }
    let reply = replies(request)
    let url = request.url ?? ChatGPTSignIn.tokenEndpoint
    guard
      let response = HTTPURLResponse(
        url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: nil)
    else {
      throw URLError(.badServerResponse)
    }
    return (Data(reply.body.utf8), response)
  }
}

extension URLRequest {
  /// フォーム形式の本文を読む
  var formFields: [String: String] {
    let body = httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    var fields: [String: String] = [:]
    for pair in body.split(separator: "&") {
      let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard parts.count == 2 else { continue }
      let name = String(parts[0]).removingPercentEncoding ?? ""
      fields[name] = String(parts[1]).removingPercentEncoding ?? ""
    }
    return fields
  }
}
