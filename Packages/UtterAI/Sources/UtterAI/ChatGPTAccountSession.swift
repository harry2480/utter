import Foundation

/// ループバック（`127.0.0.1`）でコールバックを待ち受ける口（S3）。macOS アプリが Network.framework で実装し、
/// テストは `StubChatGPTLoopbackServer` を使う。UtterAI は待ち受けの OS の API に依存しない。
public protocol ChatGPTLoopbackServer: Sendable {
  /// `127.0.0.1` の空いているポートで待ち受けを始める。ブラウザを開く前に呼ぶ（S3）
  func start() async throws(ChatGPTSignInError) -> any ChatGPTLoopbackListener
}

/// 待ち受け中の1回分のループバック。
public protocol ChatGPTLoopbackListener: Sendable {
  /// 待ち受けているポート
  var port: UInt16 { get }
  /// `/auth/callback` に届いた最初の要求の URL（`http://127.0.0.1:<port>/auth/callback?…`）を返す。
  /// 呼び出し元の Task がキャンセルされたら `.cancelled` を投げる。URL には認可コードが入るため、ログに出さない
  func callback() async throws(ChatGPTSignInError) -> URL
  /// 待ち受けをやめる。何度呼んでもよい
  func stop()
}

/// システムブラウザで URL を開く口（S3）。macOS アプリが `NSWorkspace` で実装する
public protocol ChatGPTBrowserOpening: Sendable {
  /// 開けたら `true`。URL には ID トークンが入りうるため、ログに出さない
  func open(_ url: URL) async -> Bool
}

/// このインストールの Sign in with ChatGPT のアカウント（S3, S6, S7, AC-12）。
///
/// - サインイン: ループバックで待ち受けてからシステムブラウザで認可要求を開き、コールバックを検証してコードを交換する。
///   ID トークンを検証し、プラン利用のスコープを確かめてから保存する。初回は `dynamic_agent_client` で登録し、
///   発行されたクライアントID を保存して次から使う。`ext_agent_host_id` はインストールごとに一度だけ作って保持する
/// - トークンは `ChatGPTAccountStore`（Keychain）にだけ保存し、ログ・エラーに出さない
/// - リフレッシュトークンは更新のたびに入れ替わるため、更新は同時に1つだけ行い、待っている呼び出しは同じ結果を使う（S6）
/// - サインアウト: リフレッシュトークンの失効を試してからトークンを消す。登録とホスト ID は残す（S6）
/// - 利用上限（429）のあとは、利用者が再開するまでプラン利用の送信を止める。対象外（403）のあとは、
///   サインインし直すまで同じ送信を繰り返さない（S7）
public actor ChatGPTAccountSession {
  /// 設定画面に出す状態
  public enum Status: Hashable, Sendable {
    /// サインインしていない。`hasRegistration` は以前に登録したか（次は保存したクライアントID を使う）
    case signedOut(hasRegistration: Bool)
    /// サインイン済み。`email` は ID トークンのメールアドレス
    case signedIn(email: String?, planUsage: PlanUsage)
    /// 保存先（Keychain）を読めない
    case unavailable
  }

  /// プラン利用の状態（S7）
  public enum PlanUsage: Hashable, Sendable {
    /// 使える（「Using ChatGPT plan」）
    case enabled
    /// サインインはしているが、プラン利用（`chatgpt.tokens.use.direct`）が許可されていない
    case notGranted
    /// 利用上限に達した。利用者が「再開」するまで送らない
    case pausedForUsageLimit
    /// 利用者・ワークスペース・ポリシーの点で使えない。サインインし直すまで送らない
    case notEligible
  }

  /// サインアウトの結果（S6）
  public enum SignOutResult: Hashable, Sendable {
    /// 失効を確かめてから消した
    case revoked
    /// この Mac のトークンは消したが、失効を確かめられなかった。ChatGPT の設定から接続を外せる
    case revocationUnconfirmed
  }

  /// 期限のこの時間前からリフレッシュする
  static let refreshMargin: TimeInterval = 120
  /// `expires_in` がないときのアクセストークンの期限（S8 の 3600 秒）
  static let defaultExpiresIn = 3600

  private let store: any ChatGPTAccountStore
  private let authClient: any ChatGPTAuthClient
  private let validator: ChatGPTIDTokenValidator
  private let signInTimeout: Duration
  private let now: @Sendable () -> Date

  private var record: ChatGPTAccountRecord?
  private var isLoaded = false
  private var loadFailed = false
  private var isSigningIn = false
  private var block: PlanUsage?
  private var refreshTask: Task<Result<ChatGPTTokens, AIProviderError>, Never>?

  /// - Parameters:
  ///   - store: 記録の保存先（Keychain）
  ///   - authClient: 認証サーバーとのやりとり
  ///   - signInTimeout: ブラウザでのサインインを待つ時間の上限
  ///   - now: 現在時刻（トークンの期限の判定）
  public init(
    store: any ChatGPTAccountStore,
    authClient: any ChatGPTAuthClient = OpenAIAuthClient(),
    signInTimeout: Duration = .seconds(300),
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.init(
      store: store, authClient: authClient, validator: ChatGPTIDTokenValidator(),
      signInTimeout: signInTimeout, now: now)
  }

  init(
    store: any ChatGPTAccountStore,
    authClient: any ChatGPTAuthClient,
    validator: ChatGPTIDTokenValidator,
    signInTimeout: Duration,
    now: @escaping @Sendable () -> Date
  ) {
    self.store = store
    self.authClient = authClient
    self.validator = validator
    self.signInTimeout = signInTimeout
    self.now = now
  }

  // MARK: - 状態

  public func status() -> Status {
    loadIfNeeded()
    if loadFailed {
      return .unavailable
    }
    guard let record, let tokens = record.tokens else {
      return .signedOut(hasRegistration: record?.registration != nil)
    }
    let planUsage: PlanUsage = tokens.allowsPlanUsage ? (block ?? .enabled) : .notGranted
    return .signedIn(email: record.registration?.email, planUsage: planUsage)
  }

  /// 初回のサインイン後の説明（S11）をまだ出していないか。プラン利用が使えるときだけ `true`
  public func needsPlanWelcome() -> Bool {
    guard case .signedIn(_, .enabled) = status(), let record else { return false }
    return !record.hasShownPlanWelcome
  }

  /// 初回のサインイン後の説明を出したことを記録する。次のサインインでは出さない
  public func markPlanWelcomeShown() {
    loadIfNeeded()
    guard var updated = record, !updated.hasShownPlanWelcome else { return }
    updated.hasShownPlanWelcome = true
    record = updated
    try? store.save(updated)
  }

  /// 利用上限で止めたプラン利用を、利用者の操作で再開する（S7: 回復時刻を推測しない）
  public func resumePlanUsage() {
    if block == .pausedForUsageLimit {
      block = nil
    }
  }

  // MARK: - サインイン

  /// サインインする（S3）。成功したら新しい状態を返す。
  ///
  /// - Parameters:
  ///   - server: ループバックの待ち受け
  ///   - browser: システムブラウザ
  ///   - requestsConsent: プラン利用を断ったあとに、利用者が明示的に有効にし直すとき `true`（S7）。
  ///     通常のサインインでは同意画面を強制しない
  public func signIn(
    server: any ChatGPTLoopbackServer, browser: any ChatGPTBrowserOpening,
    requestsConsent: Bool = false
  ) async throws(ChatGPTSignInError) -> Status {
    guard !isSigningIn else { throw .alreadyInProgress }
    isSigningIn = true
    defer { isSigningIn = false }

    let current = try prepareRecord()
    let listener = try await server.start()
    defer { listener.stop() }
    let attempt = ChatGPTAuthorizationAttempt(
      secrets: .generate(), port: listener.port, registration: current.registration,
      hostID: current.hostID, idTokenHint: current.tokens?.idToken,
      requestsConsent: requestsConsent)
    guard await browser.open(attempt.authorizationURL) else { throw .browserUnavailable }
    let callbackURL = try await waitForCallback(listener)
    let grant = try attempt.validateCallback(callbackURL)
    let response = try await authClient.exchangeCode(
      ChatGPTCodeExchange(
        code: grant.code, clientID: grant.clientID,
        codeVerifier: attempt.secrets.codeVerifier, redirectURI: attempt.redirectURI))
    // プラン利用には offline_access のリフレッシュトークンと、ID トークンが要る（S3, S8）
    guard let idToken = response.idToken, let refreshToken = response.refreshToken else {
      throw .invalidResponse
    }
    let keys = try await authClient.signingKeys()
    let identity = try validator.validate(
      idToken, keys: keys, clientID: grant.clientID, nonce: attempt.secrets.nonce, now: now())
    // 再認可では、選んだアカウントと同じアカウントであることを確かめてから置き換える（S3）
    if let registration = current.registration, registration.subject != identity.subject {
      throw .accountMismatch
    }
    if Task.isCancelled {
      throw .cancelled
    }

    var updated = current
    updated.registration = ChatGPTRegistration(
      clientID: grant.clientID, subject: identity.subject, email: identity.email)
    updated.tokens = makeTokens(
      from: response, refreshToken: refreshToken, idToken: idToken, previousScopes: [])
    do throws(ChatGPTAccountStoreError) {
      try store.save(updated)
    } catch {
      throw .storageFailed
    }
    // 進行中の更新は前のトークンのもののため、結果を使わせない（`performRefresh` が置き換えを確かめる）
    record = updated
    block = nil
    return status()
  }

  /// 記録を読み、なければホスト ID を作って保存する（S2: 最初のサインインの前に作って保持する）
  private func prepareRecord() throws(ChatGPTSignInError) -> ChatGPTAccountRecord {
    loadIfNeeded()
    if loadFailed {
      throw .storageFailed
    }
    if let record {
      return record
    }
    let created = ChatGPTAccountRecord(hostID: .generate())
    do throws(ChatGPTAccountStoreError) {
      try store.save(created)
    } catch {
      throw .storageFailed
    }
    record = created
    return created
  }

  /// コールバックを待つ。上限時間を過ぎたら `.timedOut`、呼び出し元がキャンセルしたら `.cancelled`
  private func waitForCallback(
    _ listener: any ChatGPTLoopbackListener
  ) async throws(ChatGPTSignInError) -> URL {
    typealias Outcome = Result<URL, ChatGPTSignInError>
    let timeout = signInTimeout
    let result = await withTaskGroup(of: Outcome?.self) { group in
      group.addTask {
        do throws(ChatGPTSignInError) {
          return Outcome.success(try await listener.callback())
        } catch {
          return Outcome.failure(error)
        }
      }
      group.addTask {
        try? await Task.sleep(for: timeout)
        return Task.isCancelled ? nil : Outcome.failure(.timedOut)
      }
      var first = Outcome.failure(.cancelled)
      for await value in group {
        if let value {
          first = value
          break
        }
      }
      group.cancelAll()
      return first
    }
    if Task.isCancelled {
      throw .cancelled
    }
    return try result.get()
  }

  // MARK: - サインアウト

  /// サインアウトする（S6）。送信を止め、失効を試してから、アクセストークン・リフレッシュトークン・ID トークンを消す。
  /// 登録（クライアントID）とホスト ID は次のサインインのために残す
  public func signOut() async -> SignOutResult {
    // 更新の途中なら、入れ替わったあとのリフレッシュトークンを失効させる
    if let refreshTask {
      _ = await refreshTask.value
    }
    loadIfNeeded()
    guard let current = record, let tokens = current.tokens,
      let clientID = current.registration?.clientID
    else {
      return .revoked
    }
    var updated = current
    updated.tokens = nil
    // 失効を待つ間に送信しないよう、先にこの Mac の記録から消す
    record = updated
    block = nil
    try? store.save(updated)
    do throws(ChatGPTSignInError) {
      try await authClient.revoke(refreshToken: tokens.refreshToken, clientID: clientID)
      return .revoked
    } catch {
      return .revocationUnconfirmed
    }
  }

  // MARK: - 推論に使うトークン

  /// Responses API に送るアクセストークン（S4）。期限が近ければリフレッシュする。
  ///
  /// - サインインしていない・プラン利用が許可されていない・リフレッシュトークンが使えない: `.authenticationExpired`
  /// - 利用上限で止めている・対象外: `.quotaExceeded`（送らない）
  /// - 認証サーバーに届かない: `.networkUnavailable`（トークンは消さない, S7）
  func accessToken() async throws(AIProviderError) -> String {
    loadIfNeeded()
    if block != nil {
      throw .quotaExceeded
    }
    guard let tokens = record?.tokens, let clientID = record?.registration?.clientID,
      tokens.allowsPlanUsage
    else {
      throw .authenticationExpired
    }
    if tokens.expiresAt > now().addingTimeInterval(Self.refreshMargin) {
      return tokens.accessToken
    }
    let task: Task<Result<ChatGPTTokens, AIProviderError>, Never>
    if let refreshTask {
      task = refreshTask
    } else {
      task = Task { await self.performRefresh(tokens, clientID: clientID) }
      refreshTask = task
    }
    // 呼び出し元がキャンセルしても更新は止めない（入れ替わったトークンを受け取りそこねないため）
    let result = await task.value
    if Task.isCancelled {
      throw .cancelled
    }
    return try result.get().accessToken
  }

  /// リフレッシュする（S6）。同時に1つだけ動き、終わったら `refreshTask` を空にする
  private func performRefresh(
    _ tokens: ChatGPTTokens, clientID: String
  ) async -> Result<ChatGPTTokens, AIProviderError> {
    defer { refreshTask = nil }
    let response: ChatGPTTokenResponse
    do throws(ChatGPTSignInError) {
      response = try await authClient.refresh(
        refreshToken: tokens.refreshToken, clientID: clientID)
    } catch {
      return .failure(handleRefreshFailure(error, of: tokens))
    }
    // 待つ間にサインアウト・サインインし直していたら、古いトークンの結果で置き換えない
    guard var updated = record, updated.tokens?.refreshToken == tokens.refreshToken else {
      return .failure(.authenticationExpired)
    }
    let refreshed = makeTokens(
      from: response, refreshToken: response.refreshToken ?? tokens.refreshToken,
      idToken: tokens.idToken, previousScopes: tokens.scopes)
    // アクセストークン・期限・スコープ・リフレッシュトークンをまとめて置き換える（S3）
    updated.tokens = refreshed
    record = updated
    // 保存できなくても、この起動の間は新しいトークンを使う（古いリフレッシュトークンはもう使えない）
    try? store.save(updated)
    guard refreshed.allowsPlanUsage else {
      return .failure(.authenticationExpired)
    }
    return .success(refreshed)
  }

  /// リフレッシュの失敗を対応づける（S7）。使えないリフレッシュトークンは消し、一時的な失敗では消さない
  private func handleRefreshFailure(
    _ error: ChatGPTSignInError, of tokens: ChatGPTTokens
  ) -> AIProviderError {
    switch error {
    case .refreshTokenUnusable:
      if var updated = record, updated.tokens?.refreshToken == tokens.refreshToken {
        updated.tokens = nil
        record = updated
        try? store.save(updated)
      }
      return .authenticationExpired
    case .cancelled:
      return .cancelled
    case .networkUnavailable, .timedOut:
      return .networkUnavailable
    default:
      // invalid_client などの設定の誤り。トークンは消さず、送らない
      return .invalidResponse
    }
  }

  /// 推論の失敗を記録する（S7）。利用上限と対象外のあとは送らない
  func noteFailure(_ failure: ChatGPTPlanFailure) {
    switch failure {
    case .usageLimitExceeded:
      block = .pausedForUsageLimit
    case .notEligible:
      block = .notEligible
    default:
      break
    }
  }

  // MARK: - 保存

  private func loadIfNeeded() {
    guard !isLoaded else { return }
    do throws(ChatGPTAccountStoreError) {
      record = try store.load()
      isLoaded = true
      loadFailed = false
    } catch {
      // Mac のロック中などで読めない。次の呼び出しで読み直す
      loadFailed = true
    }
  }

  private func makeTokens(
    from response: ChatGPTTokenResponse, refreshToken: String, idToken: String,
    previousScopes: [String]
  ) -> ChatGPTTokens {
    let expiresIn = response.expiresIn.map { max(0, $0) } ?? Self.defaultExpiresIn
    return ChatGPTTokens(
      accessToken: response.accessToken, refreshToken: refreshToken, idToken: idToken,
      expiresAt: now().addingTimeInterval(TimeInterval(expiresIn)),
      scopes: response.scope == nil ? previousScopes : response.scopes)
  }
}
