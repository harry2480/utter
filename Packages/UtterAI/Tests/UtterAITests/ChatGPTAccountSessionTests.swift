import Foundation
import Synchronization
import Testing

@testable import UtterAI

struct ChatGPTAccountSessionTests {
  /// ブラウザで開いた認可要求の nonce を、コード交換の応答に渡す入れ物
  final class NonceBox: Sendable {
    let value = Mutex<String?>(nil)
  }

  /// 認可要求の nonce を覚えてそのまま返すフローと、その nonce の ID トークンを返す認証サーバー
  private func signInFixture(
    subject: String = ChatGPTTestSupport.subject,
    scope: String? = ChatGPTTestSupport.planScope,
    respond: (@Sendable (URL) -> URL?)? = nil
  ) async -> (StubChatGPTSignInFlow, StubChatGPTAuthClient) {
    let box = NonceBox()
    let flow = StubChatGPTSignInFlow { url in
      box.value.withLock { $0 = ChatGPTTestSupport.query(url)["nonce"] }
      return respond?(url) ?? StubChatGPTSignInFlow.callback(for: url)
    }
    let client = StubChatGPTAuthClient(keys: [ChatGPTTestSupport.signingKey])
    await client.setExchangeHandler { _ in
      let nonce = box.value.withLock { $0 } ?? ""
      let idToken = ChatGPTTestSupport.idToken(
        claims: ChatGPTTestSupport.claims(nonce: nonce, subject: subject))
      return .success(ChatGPTTestSupport.tokenResponse(idToken: idToken, scope: scope))
    }
    return (flow, client)
  }

  // MARK: - サインイン

  @Test("S3, S2: 初回はホスト ID を作って保存し、動的登録で発行されたクライアントID とトークンを保存する")
  func firstSignIn() async throws {
    let store = StubChatGPTAccountStore()
    let (flow, client) = await signInFixture()
    let session = ChatGPTTestSupport.session(store: store, authClient: client)

    let status = try await session.signIn(server: flow, browser: flow)

    #expect(status == .signedIn(email: ChatGPTTestSupport.email, planUsage: .enabled))
    let record = try #require(store.storedRecord)
    #expect(record.hostID.rawValue.hasPrefix("urn:uuid:"))
    #expect(record.registration?.clientID == ChatGPTTestSupport.clientID)
    #expect(record.registration?.subject == ChatGPTTestSupport.subject)
    #expect(record.tokens?.accessToken == "access-1")
    #expect(record.tokens?.refreshToken == "refresh-1")
    #expect(record.tokens?.expiresAt == ChatGPTTestSupport.now.addingTimeInterval(3600))

    // コード交換は発行済みのクライアントID・同じリダイレクト URI・PKCE の検証子で行う
    let opened = try #require(flow.openedURLs.first)
    let query = ChatGPTTestSupport.query(opened)
    #expect(query["client_id"] == "dynamic_agent_client")
    #expect(query["ext_agent_host_id"] == record.hostID.rawValue)
    let exchange = try #require(await client.exchanges.first)
    #expect(exchange.clientID == ChatGPTTestSupport.clientID)
    #expect(exchange.redirectURI.absoluteString == query["redirect_uri"])
    #expect(
      ChatGPTAuthorizationSecrets.codeChallenge(for: exchange.codeVerifier)
        == query["code_challenge"])
    // ブラウザを開く前に待ち受けを始め、終わったらやめる
    #expect(flow.startCount == 1)
    #expect(flow.stopCount == 1)
    #expect(await session.needsPlanWelcome())
  }

  @Test("S3, S6: 2回目は保存したクライアントID・同じホスト ID・ID トークンのヒントで再認可する")
  func secondSignInReusesRegistration() async throws {
    var record = ChatGPTTestSupport.signedInRecord()
    record.tokens = nil
    let store = StubChatGPTAccountStore(record: record)
    let (flow, client) = await signInFixture()
    let session = ChatGPTTestSupport.session(store: store, authClient: client)
    #expect(await session.status() == .signedOut(hasRegistration: true))

    _ = try await session.signIn(server: flow, browser: flow)

    let query = ChatGPTTestSupport.query(try #require(flow.openedURLs.first))
    #expect(query["client_id"] == ChatGPTTestSupport.clientID)
    #expect(query["agent_name_hint"] == nil)
    #expect(query["ext_agent_host_id"] == record.hostID.rawValue)
    #expect(query["login_hint"] == ChatGPTTestSupport.email)
    // サインアウトしたあとは ID トークンを持たないため、ヒントも送らない（S6）
    #expect(query["id_token_hint"] == nil)
    #expect(store.storedRecord?.hostID == record.hostID)
  }

  @Test("S3, S7: プラン利用のスコープがなければサインインは保ち、プラン利用を無効として送らない")
  func signInWithoutPlanScope() async throws {
    let store = StubChatGPTAccountStore()
    let (flow, client) = await signInFixture(scope: "openid profile email offline_access")
    let session = ChatGPTTestSupport.session(store: store, authClient: client)

    let status = try await session.signIn(server: flow, browser: flow)

    #expect(status == .signedIn(email: ChatGPTTestSupport.email, planUsage: .notGranted))
    await #expect(throws: AIProviderError.authenticationExpired) {
      try await session.accessToken()
    }
    #expect(!(await session.needsPlanWelcome()))
  }

  @Test("S3: state が一致しない・同意しなかったコールバックではコードを交換せず、トークンを保存しない")
  func rejectedCallbacks() async throws {
    let forged: @Sendable (URL) -> URL? = {
      StubChatGPTSignInFlow.callback(for: $0, state: "forged")
    }
    let denied: @Sendable (URL) -> URL? = {
      StubChatGPTSignInFlow.callback(for: $0, code: nil, error: "access_denied")
    }
    let cases: [(@Sendable (URL) -> URL?, ChatGPTSignInError)] = [
      (forged, .stateMismatch), (denied, .accessDenied),
    ]
    for (respond, expected) in cases {
      let store = StubChatGPTAccountStore()
      let (flow, client) = await signInFixture(respond: respond)
      let session = ChatGPTTestSupport.session(store: store, authClient: client)
      await #expect(throws: expected) {
        try await session.signIn(server: flow, browser: flow)
      }
      #expect(await client.exchanges.isEmpty)
      #expect(store.storedRecord?.tokens == nil)
      #expect(flow.stopCount == 1)
    }
  }

  @Test("S3: コールバックが来なければ上限時間で終わる")
  func signInTimesOut() async {
    let flow = StubChatGPTSignInFlow { _ in nil }
    let session = ChatGPTTestSupport.session(
      store: StubChatGPTAccountStore(), authClient: StubChatGPTAuthClient(),
      signInTimeout: .milliseconds(50))
    await #expect(throws: ChatGPTSignInError.timedOut) {
      try await session.signIn(server: flow, browser: flow)
    }
  }

  @Test("S3: 再認可で別のアカウントが返ったら置き換えない")
  func accountMismatch() async throws {
    let original = ChatGPTTestSupport.signedInRecord()
    let store = StubChatGPTAccountStore(record: original)
    let (flow, client) = await signInFixture(subject: "another-subject")
    let session = ChatGPTTestSupport.session(store: store, authClient: client)
    await #expect(throws: ChatGPTSignInError.accountMismatch) {
      try await session.signIn(server: flow, browser: flow)
    }
    #expect(store.storedRecord == original)
  }

  @Test("AC-12: 保存先を読めなければサインインしない")
  func storeUnavailable() async {
    let store = StubChatGPTAccountStore()
    store.setLoadFailure(.operationFailed(code: -25308))
    let (flow, client) = await signInFixture()
    let session = ChatGPTTestSupport.session(store: store, authClient: client)
    #expect(await session.status() == .unavailable)
    await #expect(throws: ChatGPTSignInError.storageFailed) {
      try await session.signIn(server: flow, browser: flow)
    }
    #expect(flow.openedURLs.isEmpty)
  }

  // MARK: - リフレッシュ

  @Test("S6: 同時に求められた更新は1回だけ行い、入れ替わったリフレッシュトークンを保存する")
  func refreshIsSerialized() async throws {
    let store = StubChatGPTAccountStore(
      record: ChatGPTTestSupport.signedInRecord(
        expiresAt: ChatGPTTestSupport.now.addingTimeInterval(10)))
    let client = StubChatGPTAuthClient(refreshResults: [
      .success(ChatGPTTestSupport.tokenResponse(access: "access-2", refresh: "refresh-2"))
    ])
    await client.setHoldsRefresh(true)
    let session = ChatGPTTestSupport.session(store: store, authClient: client)

    let first = Task { try await session.accessToken() }
    while await client.refreshedTokens.isEmpty {
      await Task.yield()
    }
    let second = Task { try await session.accessToken() }
    try await Task.sleep(for: .milliseconds(100))
    await client.releaseRefresh()

    #expect(try await first.value == "access-2")
    #expect(try await second.value == "access-2")
    #expect(await client.refreshedTokens == ["refresh-1"])
    #expect(store.storedRecord?.tokens?.refreshToken == "refresh-2")
    #expect(store.storedRecord?.tokens?.accessToken == "access-2")
  }

  @Test("S7: 使えないリフレッシュトークンは消して再サインインを求め、登録とホスト ID は残す")
  func unusableRefreshToken() async throws {
    let original = ChatGPTTestSupport.signedInRecord(
      expiresAt: ChatGPTTestSupport.now.addingTimeInterval(-1))
    let store = StubChatGPTAccountStore(record: original)
    let client = StubChatGPTAuthClient(refreshResults: [.failure(.refreshTokenUnusable)])
    let session = ChatGPTTestSupport.session(store: store, authClient: client)

    await #expect(throws: AIProviderError.authenticationExpired) {
      try await session.accessToken()
    }
    #expect(store.storedRecord?.tokens == nil)
    #expect(store.storedRecord?.registration == original.registration)
    #expect(store.storedRecord?.hostID == original.hostID)
    #expect(await session.status() == .signedOut(hasRegistration: true))
  }

  @Test("S7: 認証サーバーに届かないときはトークンを消さない")
  func refreshNetworkFailureKeepsTokens() async throws {
    let original = ChatGPTTestSupport.signedInRecord(
      expiresAt: ChatGPTTestSupport.now.addingTimeInterval(-1))
    let store = StubChatGPTAccountStore(record: original)
    let client = StubChatGPTAuthClient(refreshResults: [.failure(.networkUnavailable)])
    let session = ChatGPTTestSupport.session(store: store, authClient: client)

    await #expect(throws: AIProviderError.networkUnavailable) {
      try await session.accessToken()
    }
    #expect(store.storedRecord == original)
  }

  @Test("S8: 期限まで余裕があれば更新せずに保存済みのアクセストークンを使う")
  func validTokenIsReused() async throws {
    let store = StubChatGPTAccountStore(record: ChatGPTTestSupport.signedInRecord())
    let client = StubChatGPTAuthClient()
    let session = ChatGPTTestSupport.session(store: store, authClient: client)
    #expect(try await session.accessToken() == "access-1")
    #expect(await client.refreshedTokens.isEmpty)
  }

  // MARK: - サインアウト・利用上限

  @Test("S6: サインアウトはリフレッシュトークンを失効させてトークンを消し、登録とホスト ID は残す")
  func signOut() async throws {
    let original = ChatGPTTestSupport.signedInRecord()
    let store = StubChatGPTAccountStore(record: original)
    let client = StubChatGPTAuthClient()
    let session = ChatGPTTestSupport.session(store: store, authClient: client)

    #expect(await session.signOut() == .revoked)
    #expect(await client.revokedTokens == ["refresh-1"])
    #expect(store.storedRecord?.tokens == nil)
    #expect(store.storedRecord?.registration == original.registration)
    #expect(store.storedRecord?.hostID == original.hostID)
    await #expect(throws: AIProviderError.authenticationExpired) {
      try await session.accessToken()
    }
  }

  @Test("S6: 失効を確かめられなくても、この Mac のトークンは消す")
  func signOutWithoutRevocation() async throws {
    let store = StubChatGPTAccountStore(record: ChatGPTTestSupport.signedInRecord())
    let client = StubChatGPTAuthClient(revokeError: .networkUnavailable)
    let session = ChatGPTTestSupport.session(store: store, authClient: client)
    #expect(await session.signOut() == .revocationUnconfirmed)
    #expect(store.storedRecord?.tokens == nil)
  }

  @Test("S7: 利用上限のあとは再開するまで送らず、対象外のあとはサインインし直すまで送らない")
  func usageLimitPausesPlanUsage() async throws {
    let store = StubChatGPTAccountStore(record: ChatGPTTestSupport.signedInRecord())
    let session = ChatGPTTestSupport.session(store: store, authClient: StubChatGPTAuthClient())

    await session.noteFailure(.usageLimitExceeded)
    #expect(
      await session.status()
        == .signedIn(email: ChatGPTTestSupport.email, planUsage: .pausedForUsageLimit))
    await #expect(throws: AIProviderError.quotaExceeded) { try await session.accessToken() }
    await session.resumePlanUsage()
    #expect(try await session.accessToken() == "access-1")

    await session.noteFailure(.notEligible)
    await session.resumePlanUsage()
    #expect(
      await session.status() == .signedIn(email: ChatGPTTestSupport.email, planUsage: .notEligible))
    await #expect(throws: AIProviderError.quotaExceeded) { try await session.accessToken() }
  }

  @Test("AC-12: 記録とトークンは文字列表現に出さない")
  func recordIsRedacted() throws {
    let record = ChatGPTTestSupport.signedInRecord()
    let texts = [
      "\(record)", String(reflecting: record), "\(try #require(record.tokens))",
      "\(try #require(record.registration))", "\(ChatGPTTestSupport.tokenResponse())",
    ]
    for text in texts {
      for secret in ["access-1", "refresh-1", "previous-id-token", ChatGPTTestSupport.clientID] {
        #expect(!text.contains(secret))
      }
    }
  }
}
