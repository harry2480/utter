import CryptoKit
import Foundation

/// Sign in with ChatGPT（ChatGPT plan usage, OSS 向けの動的登録）の公開ドキュメントにある値（AI-02, #50）。
///
/// 値は docs/Phase0検証-ChatGPT登録条件.md の出典（S3〜S8）と、OpenID Connect の discovery 文書
/// （`https://auth.openai.com/.well-known/openid-configuration`）にあるものだけを使う。
/// 他製品のクライアントID や非公開エンドポイント（ChatGPT の `backend-api` など）は使わない。
/// リリース前に出典を再確認する（AI-02）。
public enum ChatGPTSignIn {
  /// 認可エンドポイント（S3）。システムブラウザで開く
  public static let authorizationEndpoint = URL(
    string: "https://auth.openai.com/api/accounts/authorize")!
  /// トークンエンドポイント（S3, S6）。コード交換とリフレッシュに使う
  static let tokenEndpoint = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
  /// discovery 文書（S6）。サインアウト時に `revocation_endpoint` を読む
  static let discoveryEndpoint = URL(
    string: "https://auth.openai.com/.well-known/openid-configuration")!
  /// ID トークンの署名鍵（JWKS）。discovery 文書の `jwks_uri` と同じ値
  static let jwksEndpoint = URL(string: "https://auth.openai.com/.well-known/jwks.json")!
  /// ID トークンの `iss` に求める値（discovery 文書の `issuer`）
  static let issuer = "https://auth.openai.com"
  /// 認証のホスト。これ以外のホストへトークン・コードを送らない
  static let authHost = "auth.openai.com"
  /// 認可要求とコード交換・リフレッシュで送る `resource`（S3, S6）
  static let resource = "https://api.openai.com/v1"
  /// 推論の送信先（S4）。公開の Responses API に限る
  static let responsesEndpoint = URL(string: "https://api.openai.com/v1/responses")!
  /// アカウントで使えるモデルの一覧（S4）
  static let modelsEndpoint = URL(string: "https://api.openai.com/v1/models")!
  /// ChatGPT 側で利用状況とアプリごとの上限を管理する画面（S6, S11 の「Manage usage」）
  public static let manageUsageURL = URL(string: "https://chatgpt.com/settings/usage")!

  /// 初回の動的登録の入口（S3）。発行済みのクライアントID としては保存しない
  static let dynamicClientID = "dynamic_agent_client"
  /// 初回の動的登録で送るアプリ名（S3）。全インストールで同じ値にする
  static let agentNameHint = "utter"
  /// 要求するスコープ（S3）。ID 用とプラン利用用
  static let scopes = [
    "openid", "profile", "email", "offline_access", "resource.invoke",
    "chatgpt.tokens.use.direct",
  ]
  /// プラン利用の許可を表すスコープ（S3, S7）。付与されていなければ推論に進まない
  static let planUsageScope = "chatgpt.tokens.use.direct"
  /// ループバックのコールバックのパス（S3）。変えてよいのはポートだけ
  public static let callbackPath = "/auth/callback"
  /// ループバックのコールバックのホスト（S3）。`localhost` に置き換えない
  public static let callbackHost = "127.0.0.1"

  /// ループバックのリダイレクト URI（`http://127.0.0.1:<port>/auth/callback`）
  public static func redirectURI(port: UInt16) -> URL {
    var components = URLComponents()
    components.scheme = "http"
    components.host = callbackHost
    components.port = Int(port)
    components.path = callbackPath
    return components.url!
  }
}

// MARK: - PKCE・state・nonce

/// 1回の認可の試行で使う乱数（S3）。試行ごとに新しく作り、使い回さない。
///
/// 値は認可要求とコード交換にだけ使い、ログ・エラーに出さない。
struct ChatGPTAuthorizationSecrets: Hashable, Sendable {
  /// PKCE の検証子（RFC 7636。43〜128 文字の base64url）
  let codeVerifier: String
  let state: String
  let nonce: String

  /// 暗号論的な乱数で作る（`SystemRandomNumberGenerator`）
  static func generate() -> ChatGPTAuthorizationSecrets {
    var generator = SystemRandomNumberGenerator()
    return generate(using: &generator)
  }

  static func generate(
    using generator: inout some RandomNumberGenerator
  ) -> ChatGPTAuthorizationSecrets {
    ChatGPTAuthorizationSecrets(
      codeVerifier: randomString(byteCount: 32, using: &generator),
      state: randomString(byteCount: 32, using: &generator),
      nonce: randomString(byteCount: 32, using: &generator))
  }

  /// PKCE の `code_challenge`（S256）。検証子の SHA-256 を base64url（パディングなし）にしたもの
  var codeChallenge: String {
    Self.codeChallenge(for: codeVerifier)
  }

  static func codeChallenge(for verifier: String) -> String {
    base64URLEncoded(Data(SHA256.hash(data: Data(verifier.utf8))))
  }

  private static func randomString(
    byteCount: Int, using generator: inout some RandomNumberGenerator
  ) -> String {
    let bytes = (0..<byteCount).map { _ in UInt8(truncatingIfNeeded: generator.next()) }
    return base64URLEncoded(Data(bytes))
  }
}

/// クエリ・フォームの値に使える文字（RFC 3986 の非予約文字）
private let unreservedCharacters = CharacterSet(
  charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

/// 名前と値をすべて URL エンコードして `&` でつなぐ。クエリと `application/x-www-form-urlencoded` の本文に使う
func formEncoded(_ items: [URLQueryItem]) -> String {
  items.map { item in
    let name = item.name.addingPercentEncoding(withAllowedCharacters: unreservedCharacters) ?? ""
    let value =
      item.value?.addingPercentEncoding(withAllowedCharacters: unreservedCharacters) ?? ""
    return "\(name)=\(value)"
  }.joined(separator: "&")
}

/// base64url（パディングなし, RFC 4648 5節）
func base64URLEncoded(_ data: Data) -> String {
  data.base64EncodedString()
    .replacingOccurrences(of: "+", with: "-")
    .replacingOccurrences(of: "/", with: "_")
    .replacingOccurrences(of: "=", with: "")
}

/// base64url（パディングなし）を読む。読めなければ `nil`
func base64URLDecoded(_ string: some StringProtocol) -> Data? {
  var base64 = string.replacingOccurrences(of: "-", with: "+")
    .replacingOccurrences(of: "_", with: "/")
  let remainder = base64.count % 4
  if remainder > 0 {
    base64 += String(repeating: "=", count: 4 - remainder)
  }
  return Data(base64Encoded: base64)
}

// MARK: - 認可の試行

/// 1回の認可の試行（S3）。ループバックの待ち受けを始めてから作り、コールバックを受けるまで持つ。
///
/// 初回は `dynamic_agent_client` と `agent_name_hint` を、2回目以降は保存した発行済みのクライアントID を送る。
/// `ext_agent_host_id` は毎回同じ値を送る（S6）。
struct ChatGPTAuthorizationAttempt: Sendable {
  let secrets: ChatGPTAuthorizationSecrets
  let redirectURI: URL
  /// 認可要求で送るクライアントID。初回は `dynamic_agent_client`
  let requestedClientID: String
  let hostID: ChatGPTHostID
  /// 再認可のときの ID トークン（S6 の `id_token_hint`）。期限切れでもよい
  let idTokenHint: String?
  /// 再認可のときのメールアドレス（S6 の `login_hint`）
  let loginHint: String?
  /// プラン利用を断ったあとに、利用者が明示的に有効にし直すときだけ同意画面を出す（S7 の `prompt=consent`）
  let requestsConsent: Bool

  /// 初回の動的登録か
  var isNewRegistration: Bool {
    requestedClientID == ChatGPTSignIn.dynamicClientID
  }

  init(
    secrets: ChatGPTAuthorizationSecrets, port: UInt16, registration: ChatGPTRegistration?,
    hostID: ChatGPTHostID, idTokenHint: String?, requestsConsent: Bool
  ) {
    self.secrets = secrets
    self.redirectURI = ChatGPTSignIn.redirectURI(port: port)
    self.requestedClientID = registration?.clientID ?? ChatGPTSignIn.dynamicClientID
    self.hostID = hostID
    // 初回の登録ではヒントを送らない（どのアカウントかはまだ決まっていない）
    self.idTokenHint = registration == nil ? nil : idTokenHint
    self.loginHint = registration?.email
    self.requestsConsent = requestsConsent
  }

  /// システムブラウザで開く認可要求の URL（S3）。ID トークンを含みうるため、ログ・診断に出さない（S6）
  var authorizationURL: URL {
    var items: [URLQueryItem] = [
      URLQueryItem(name: "client_id", value: requestedClientID),
      URLQueryItem(name: "ext_agent_host_id", value: hostID.rawValue),
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
      URLQueryItem(name: "scope", value: ChatGPTSignIn.scopes.joined(separator: " ")),
      URLQueryItem(name: "resource", value: ChatGPTSignIn.resource),
      URLQueryItem(name: "state", value: secrets.state),
      URLQueryItem(name: "nonce", value: secrets.nonce),
      URLQueryItem(name: "code_challenge_method", value: "S256"),
      URLQueryItem(name: "code_challenge", value: secrets.codeChallenge),
    ]
    if isNewRegistration {
      items.append(URLQueryItem(name: "agent_name_hint", value: ChatGPTSignIn.agentNameHint))
    }
    if let idTokenHint {
      items.append(URLQueryItem(name: "id_token_hint", value: idTokenHint))
    }
    if let loginHint {
      items.append(URLQueryItem(name: "login_hint", value: loginHint))
    }
    if requestsConsent {
      items.append(URLQueryItem(name: "prompt", value: "consent"))
    }
    var components = URLComponents(
      url: ChatGPTSignIn.authorizationEndpoint, resolvingAgainstBaseURL: false)!
    // 値はすべて URL エンコードする（S3）。URLComponents は `+`・`:`・`/` をエスケープしないため、非予約文字以外を符号化する
    components.percentEncodedQuery = formEncoded(items)
    return components.url!
  }

  /// ループバックで受けたコールバックを検証し、交換に使う認可コードとクライアントID を返す（S3）。
  ///
  /// - state が一致しなければ、エラー応答でも拒否する（別の試行・偽の要求を受け付けない）
  /// - `error=access_denied` は同意の拒否として扱い、コードを交換しない
  /// - 初回の登録で発行済みのクライアントID がなければ、登録が終わっていないものとして扱う
  /// - 再認可で別のクライアントID が返ったら拒否する（別の登録で置き換えない）
  func validateCallback(_ url: URL) throws(ChatGPTSignInError) -> ChatGPTAuthorizationGrant {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      components.path == ChatGPTSignIn.callbackPath
    else {
      throw .invalidCallback
    }
    let items = components.queryItems ?? []
    func value(_ name: String) -> String? {
      items.first { $0.name == name }?.value
    }
    guard let state = value("state"), Self.constantTimeEquals(state, secrets.state) else {
      throw .stateMismatch
    }
    if let error = value("error") {
      throw error == "access_denied" ? ChatGPTSignInError.accessDenied : .authorizationFailed
    }
    guard let code = value("code"), !code.isEmpty else {
      throw .invalidCallback
    }
    let returnedClientID = value("client_id").flatMap { $0.isEmpty ? nil : $0 }
    let clientID: String
    if isNewRegistration {
      guard let returnedClientID, returnedClientID != ChatGPTSignIn.dynamicClientID else {
        throw .registrationIncomplete
      }
      clientID = returnedClientID
    } else {
      if let returnedClientID, returnedClientID != requestedClientID {
        throw .clientIDMismatch
      }
      clientID = requestedClientID
    }
    return ChatGPTAuthorizationGrant(code: code, clientID: clientID)
  }

  /// 長さ以外の情報を比較時間から漏らさない比較
  static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
    let left = Array(lhs.utf8)
    let right = Array(rhs.utf8)
    guard left.count == right.count else { return false }
    var difference: UInt8 = 0
    for index in left.indices {
      difference |= left[index] ^ right[index]
    }
    return difference == 0
  }
}

/// 検証済みのコールバックから取り出した、コード交換に使う値。値はログに出さない
struct ChatGPTAuthorizationGrant: Hashable, Sendable {
  let code: String
  /// 発行済みのクライアントID（`oaiapp_…`）。`dynamic_agent_client` ではない
  let clientID: String
}

extension ChatGPTAuthorizationGrant: CustomStringConvertible, CustomReflectable {
  var description: String { "ChatGPTAuthorizationGrant(<redacted>)" }
  var customMirror: Mirror { Mirror(self, children: []) }
}

extension ChatGPTAuthorizationSecrets: CustomStringConvertible, CustomReflectable {
  var description: String { "ChatGPTAuthorizationSecrets(<redacted>)" }
  var customMirror: Mirror { Mirror(self, children: []) }
}

extension ChatGPTAuthorizationAttempt: CustomStringConvertible, CustomReflectable {
  var description: String {
    "ChatGPTAuthorizationAttempt(newRegistration: \(isNewRegistration))"
  }

  var customMirror: Mirror {
    Mirror(self, children: ["isNewRegistration": isNewRegistration])
  }
}
