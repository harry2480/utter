import Foundation
import Testing

@testable import UtterAI

struct ChatGPTSignInTests {
  private let hostID = ChatGPTHostID(rawValue: "urn:uuid:00000000-0000-4000-8000-000000000000")

  private func attempt(
    registration: ChatGPTRegistration? = nil, idTokenHint: String? = nil,
    requestsConsent: Bool = false
  ) -> ChatGPTAuthorizationAttempt {
    ChatGPTAuthorizationAttempt(
      secrets: .generate(), port: 54321, registration: registration, hostID: hostID,
      idTokenHint: idTokenHint, requestsConsent: requestsConsent)
  }

  // MARK: - PKCE・state・nonce

  @Test("AI-02, S3: PKCE の code_challenge は検証子の SHA-256 を base64url（パディングなし）にしたもの")
  func codeChallengeMatchesRFC7636() {
    // RFC 7636 付録 B の例
    #expect(
      ChatGPTAuthorizationSecrets.codeChallenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
  }

  @Test("S3: 検証子・state・nonce は試行ごとに新しい乱数で、base64url の 43 文字")
  func secretsAreFreshPerAttempt() {
    let first = ChatGPTAuthorizationSecrets.generate()
    let second = ChatGPTAuthorizationSecrets.generate()
    #expect(first != second)
    for value in [first.codeVerifier, first.state, first.nonce] {
      #expect(value.count == 43)
      #expect(value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
    }
    #expect(Set([first.codeVerifier, first.state, first.nonce]).count == 3)
    #expect(!first.codeChallenge.contains("="))
  }

  @Test("AC-12: 試行の値は文字列表現に出さない")
  func secretsAreRedacted() {
    let attempt = attempt()
    for text in ["\(attempt.secrets)", String(reflecting: attempt.secrets), "\(attempt)"] {
      #expect(!text.contains(attempt.secrets.state))
      #expect(!text.contains(attempt.secrets.codeVerifier))
      #expect(!text.contains(attempt.secrets.nonce))
    }
  }

  // MARK: - 認可要求

  @Test("S3: 初回は dynamic_agent_client・agent_name_hint・ext_agent_host_id を送り、リダイレクトはループバック")
  func firstAuthorizationRequest() throws {
    let attempt = attempt()
    let url = attempt.authorizationURL
    #expect(url.host == "auth.openai.com")
    #expect(url.path == "/api/accounts/authorize")
    let query = ChatGPTTestSupport.query(url)
    #expect(query["client_id"] == "dynamic_agent_client")
    #expect(query["agent_name_hint"] == "utter")
    #expect(query["ext_agent_host_id"] == hostID.rawValue)
    #expect(query["redirect_uri"] == "http://127.0.0.1:54321/auth/callback")
    #expect(query["response_type"] == "code")
    #expect(query["resource"] == "https://api.openai.com/v1")
    #expect(query["code_challenge_method"] == "S256")
    #expect(query["code_challenge"] == attempt.secrets.codeChallenge)
    #expect(query["state"] == attempt.secrets.state)
    #expect(query["nonce"] == attempt.secrets.nonce)
    let scopes = Set(try #require(query["scope"]).split(separator: " ").map(String.init))
    #expect(
      scopes == [
        "openid", "profile", "email", "offline_access", "resource.invoke",
        "chatgpt.tokens.use.direct",
      ])
    #expect(query["id_token_hint"] == nil)
    #expect(query["login_hint"] == nil)
    #expect(query["prompt"] == nil)
  }

  @Test("S3, S6: 再認可は保存したクライアントID とヒントを送り、agent_name_hint は送らない")
  func reauthorizationRequest() {
    let registration = ChatGPTRegistration(
      clientID: "oaiapp_saved", subject: "sub", email: "a+b@example.com")
    let attempt = attempt(registration: registration, idTokenHint: "old-id-token")
    let query = ChatGPTTestSupport.query(attempt.authorizationURL)
    #expect(query["client_id"] == "oaiapp_saved")
    #expect(query["agent_name_hint"] == nil)
    #expect(query["ext_agent_host_id"] == hostID.rawValue)
    #expect(query["id_token_hint"] == "old-id-token")
    // `+` を空白に読み替えられないよう符号化する
    #expect(query["login_hint"] == "a+b@example.com")
    #expect(attempt.authorizationURL.absoluteString.contains("a%2Bb%40example.com"))
  }

  @Test("S7: プラン利用を有効にし直すときだけ prompt=consent を送る")
  func consentIsRequestedOnlyWhenAsked() {
    let consent = ChatGPTTestSupport.query(attempt(requestsConsent: true).authorizationURL)
    #expect(consent["prompt"] == "consent")
  }

  // MARK: - コールバックの検証

  @Test("S3: 初回の登録は code と発行済みのクライアントID を受け取る")
  func validCallbackForNewRegistration() throws {
    let attempt = attempt()
    let callback = StubChatGPTSignInFlow.callback(for: attempt.authorizationURL)
    let grant = try attempt.validateCallback(callback)
    #expect(grant.code == "test-code")
    #expect(grant.clientID == "oaiapp_test")
    #expect(!"\(grant)".contains("test-code"))
  }

  @Test("S3: state が一致しなければ拒否する（エラー応答でも）")
  func stateMismatchIsRejected() {
    let attempt = attempt()
    let forged = StubChatGPTSignInFlow.callback(for: attempt.authorizationURL, state: "forged")
    #expect(throws: ChatGPTSignInError.stateMismatch) { try attempt.validateCallback(forged) }

    let forgedError = StubChatGPTSignInFlow.callback(
      for: attempt.authorizationURL, code: nil, error: "access_denied", state: "forged")
    #expect(throws: ChatGPTSignInError.stateMismatch) { try attempt.validateCallback(forgedError) }

    let missing = URL(string: "http://127.0.0.1:54321/auth/callback?code=x&client_id=oaiapp_x")!
    #expect(throws: ChatGPTSignInError.stateMismatch) { try attempt.validateCallback(missing) }
  }

  @Test("S3: access_denied は同意の拒否、ほかのエラーは認可の失敗として、コードを交換しない")
  func errorResponses() {
    let attempt = attempt()
    let denied = StubChatGPTSignInFlow.callback(
      for: attempt.authorizationURL, code: "ignored", error: "access_denied")
    #expect(throws: ChatGPTSignInError.accessDenied) { try attempt.validateCallback(denied) }
    let failed = StubChatGPTSignInFlow.callback(
      for: attempt.authorizationURL, code: nil, error: "server_error")
    #expect(throws: ChatGPTSignInError.authorizationFailed) { try attempt.validateCallback(failed) }
  }

  @Test("S3: 初回の登録で発行済みのクライアントID がなければ登録は終わっていない")
  func newRegistrationRequiresIssuedClientID() {
    let attempt = attempt()
    let missing = StubChatGPTSignInFlow.callback(for: attempt.authorizationURL, clientID: nil)
    #expect(throws: ChatGPTSignInError.registrationIncomplete) {
      try attempt.validateCallback(missing)
    }
    let dynamic = StubChatGPTSignInFlow.callback(
      for: attempt.authorizationURL, clientID: "dynamic_agent_client")
    #expect(throws: ChatGPTSignInError.registrationIncomplete) {
      try attempt.validateCallback(dynamic)
    }
  }

  @Test("S3: 再認可はクライアントID を省けるが、違うクライアントID なら拒否する")
  func reauthorizationClientID() throws {
    let registration = ChatGPTRegistration(clientID: "oaiapp_saved", subject: "sub", email: nil)
    let attempt = attempt(registration: registration)
    let omitted = StubChatGPTSignInFlow.callback(for: attempt.authorizationURL, clientID: nil)
    #expect(try attempt.validateCallback(omitted).clientID == "oaiapp_saved")
    let other = StubChatGPTSignInFlow.callback(
      for: attempt.authorizationURL, clientID: "oaiapp_other")
    #expect(throws: ChatGPTSignInError.clientIDMismatch) { try attempt.validateCallback(other) }
  }

  @Test("S3: パスが /auth/callback でない・コードがないコールバックは受け付けない")
  func malformedCallback() throws {
    let attempt = attempt()
    let state = attempt.secrets.state
    let wrongPath = try #require(
      URL(string: "http://127.0.0.1:54321/callback?code=x&state=\(state)"))
    #expect(throws: ChatGPTSignInError.invalidCallback) { try attempt.validateCallback(wrongPath) }
    let noCode = StubChatGPTSignInFlow.callback(for: attempt.authorizationURL, code: nil)
    #expect(throws: ChatGPTSignInError.invalidCallback) { try attempt.validateCallback(noCode) }
  }

  @Test("S2: ホスト ID は urn:uuid の UUIDv4 で、作るたびに違う")
  func hostIDFormat() {
    let first = ChatGPTHostID.generate()
    #expect(first.rawValue.hasPrefix("urn:uuid:"))
    let uuid = first.rawValue.dropFirst("urn:uuid:".count)
    #expect(UUID(uuidString: String(uuid)) != nil)
    // UUIDv4 の版番号
    #expect(uuid.split(separator: "-")[2].first == "4")
    #expect(first != ChatGPTHostID.generate())
  }
}
