import Foundation
import Testing

@testable import UtterAI

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

struct OpenAIAuthClientTests {
  private static let tokenBody = #"""
    {"access_token":"access-1","refresh_token":"refresh-1","id_token":"id","token_type":"Bearer",
     "expires_in":3600,"scope":"openid chatgpt.tokens.use.direct","earliest_refresh_at":0}
    """#

  private let exchange = ChatGPTCodeExchange(
    code: "code+1", clientID: "oaiapp_test", codeVerifier: "verifier",
    redirectURI: ChatGPTSignIn.redirectURI(port: 54321))

  /// 決めた HTTP ステータスと本文を返す送信部
  private static func replying(_ status: Int, _ body: String) -> StubHTTPTransport {
    StubHTTPTransport { _ in StubHTTPTransport.Reply(status: status, body: body) }
  }

  @Test("S3: コード交換はフォーム形式で、発行済みのクライアントID・検証子・同じリダイレクト URI・resource を送る")
  func exchangeCode() async throws {
    let transport = Self.replying(200, Self.tokenBody)
    let tokens = try await OpenAIAuthClient(transport: transport).exchangeCode(exchange)
    #expect(tokens.accessToken == "access-1")
    #expect(tokens.refreshToken == "refresh-1")
    #expect(tokens.expiresIn == 3600)
    #expect(tokens.scopes == ["openid", "chatgpt.tokens.use.direct"])

    let request = try #require(transport.requests.first)
    #expect(request.url == URL(string: "https://auth.openai.com/api/accounts/oauth/token"))
    #expect(request.httpMethod == "POST")
    #expect(
      request.value(forHTTPHeaderField: "content-type") == "application/x-www-form-urlencoded")
    #expect(
      request.formFields == [
        "grant_type": "authorization_code", "client_id": "oaiapp_test", "code": "code+1",
        "code_verifier": "verifier", "redirect_uri": "http://127.0.0.1:54321/auth/callback",
        "resource": "https://api.openai.com/v1",
      ])
    // `+` は空白と読まれないよう符号化する
    let body = String(data: try #require(request.httpBody), encoding: .utf8) ?? ""
    #expect(body.contains("code=code%2B1"))
  }

  @Test("S6: リフレッシュは発行済みのクライアントID と resource を送り、scope は送らない")
  func refresh() async throws {
    let transport = Self.replying(200, Self.tokenBody)
    let client = OpenAIAuthClient(transport: transport)
    _ = try await client.refresh(refreshToken: "refresh-0", clientID: "oaiapp_test")
    let fields = try #require(transport.requests.first).formFields
    #expect(
      fields == [
        "grant_type": "refresh_token", "client_id": "oaiapp_test",
        "refresh_token": "refresh-0", "resource": "https://api.openai.com/v1",
      ])
  }

  @Test("S7: リフレッシュの使えないトークンの code は再サインインへ、invalid_client は設定の誤りへ")
  func refreshErrors() async {
    let codes = [
      "invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired",
      "refresh_token_invalidated", "refresh_token_reused",
    ]
    for code in codes {
      let client = OpenAIAuthClient(transport: Self.replying(400, #"{"error":"\#(code)"}"#))
      await #expect(throws: ChatGPTSignInError.refreshTokenUnusable) {
        try await client.refresh(refreshToken: "r", clientID: "c")
      }
    }
    let nested = OpenAIAuthClient(
      transport: Self.replying(400, #"{"error":{"code":"refresh_token_reused"}}"#))
    await #expect(throws: ChatGPTSignInError.refreshTokenUnusable) {
      try await nested.refresh(refreshToken: "r", clientID: "c")
    }
    let invalidClient = OpenAIAuthClient(
      transport: Self.replying(401, #"{"error":"invalid_client"}"#))
    await #expect(throws: ChatGPTSignInError.invalidClient) {
      try await invalidClient.refresh(refreshToken: "r", clientID: "c")
    }
    let server = OpenAIAuthClient(transport: Self.replying(503, ""))
    await #expect(throws: ChatGPTSignInError.networkUnavailable) {
      try await server.refresh(refreshToken: "r", clientID: "c")
    }
  }

  @Test("S3: コード交換の invalid_grant はコードを捨ててやり直す失敗として分ける")
  func exchangeInvalidGrant() async {
    let client = OpenAIAuthClient(transport: Self.replying(400, #"{"error":"invalid_grant"}"#))
    await #expect(throws: ChatGPTSignInError.invalidGrant) {
      try await client.exchangeCode(exchange)
    }
  }

  @Test("S6: 失効は discovery 文書の revocation_endpoint へ、token・token_type_hint・client_id を送る")
  func revoke() async throws {
    let discovery = #"{"revocation_endpoint":"https://auth.openai.com/api/accounts/oauth/revoke"}"#
    let transport = StubHTTPTransport { request in
      let isDiscovery = request.url == ChatGPTSignIn.discoveryEndpoint
      return StubHTTPTransport.Reply(status: 200, body: isDiscovery ? discovery : "")
    }
    let client = OpenAIAuthClient(transport: transport)
    try await client.revoke(refreshToken: "refresh-1", clientID: "oaiapp_test")
    let requests = transport.requests
    #expect(requests.count == 2)
    let revoke = try #require(requests.last)
    #expect(revoke.url == URL(string: "https://auth.openai.com/api/accounts/oauth/revoke"))
    #expect(
      revoke.formFields == [
        "token": "refresh-1", "token_type_hint": "refresh_token", "client_id": "oaiapp_test",
      ])
  }

  @Test("AI-02: discovery 文書が別のホストの失効先を示したら、リフレッシュトークンを送らない")
  func revokeRejectsForeignHost() async {
    let transport = Self.replying(
      200, #"{"revocation_endpoint":"https://evil.example.com/revoke"}"#)
    let client = OpenAIAuthClient(transport: transport)
    await #expect(throws: ChatGPTSignInError.invalidResponse) {
      try await client.revoke(refreshToken: "refresh-1", clientID: "oaiapp_test")
    }
    #expect(transport.requests.count == 1)
  }

  @Test("S3: JWKS から読めない鍵を除いて署名鍵を読む")
  func signingKeys() async throws {
    let body = #"""
      {"keys":[{"kty":"RSA","kid":"k1","alg":"RS256","use":"sig","n":"AQAB","e":"AQAB"},
               {"kty":"EC","crv":"P-256"}]}
      """#
    let transport = Self.replying(200, body)
    let keys = try await OpenAIAuthClient(transport: transport).signingKeys()
    #expect(keys.map(\.kid) == ["k1"])
    #expect(transport.requests.first?.url == ChatGPTSignIn.jwksEndpoint)
  }
}
