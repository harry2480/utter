import Foundation
import Synchronization

/// テスト用の `ChatGPTAuthClient`。ネットワークに出ず、決めた結果を返し、受け取った値を記録する。
///
/// リフレッシュは `holdsRefresh` を立てると `releaseRefresh()` まで返さない（更新の直列化の確認用）。
public actor StubChatGPTAuthClient: ChatGPTAuthClient {
  public typealias ExchangeHandler =
    @Sendable (ChatGPTCodeExchange) -> Result<ChatGPTTokenResponse, ChatGPTSignInError>

  public var exchangeResult: Result<ChatGPTTokenResponse, ChatGPTSignInError>
  /// 指定すると `exchangeResult` の代わりに使う（試行ごとの nonce を含む ID トークンを返すため）
  public var exchangeHandler: ExchangeHandler?
  /// リフレッシュの結果。呼ぶたびに先頭から使い、最後の1つは繰り返す
  public var refreshResults: [Result<ChatGPTTokenResponse, ChatGPTSignInError>]
  public var revokeError: ChatGPTSignInError?
  public var keys: [ChatGPTSigningKey]
  public var holdsRefresh = false

  public private(set) var exchanges: [ChatGPTCodeExchange] = []
  /// リフレッシュに使われたリフレッシュトークン（呼び出し順）
  public private(set) var refreshedTokens: [String] = []
  /// 失効させたリフレッシュトークン（呼び出し順）
  public private(set) var revokedTokens: [String] = []
  private var gate: [CheckedContinuation<Void, Never>] = []

  public init(
    exchangeResult: Result<ChatGPTTokenResponse, ChatGPTSignInError> = .failure(.rejected),
    refreshResults: [Result<ChatGPTTokenResponse, ChatGPTSignInError>] = [.failure(.rejected)],
    revokeError: ChatGPTSignInError? = nil,
    keys: [ChatGPTSigningKey] = []
  ) {
    self.exchangeResult = exchangeResult
    self.refreshResults = refreshResults
    self.revokeError = revokeError
    self.keys = keys
  }

  public func setExchangeResult(_ result: Result<ChatGPTTokenResponse, ChatGPTSignInError>) {
    exchangeResult = result
  }

  public func setExchangeHandler(_ handler: ExchangeHandler?) {
    exchangeHandler = handler
  }

  public func setRefreshResults(_ results: [Result<ChatGPTTokenResponse, ChatGPTSignInError>]) {
    refreshResults = results
  }

  public func setHoldsRefresh(_ holds: Bool) {
    holdsRefresh = holds
  }

  /// 止めていたリフレッシュを返す
  public func releaseRefresh() {
    holdsRefresh = false
    let waiting = gate
    gate = []
    for continuation in waiting {
      continuation.resume()
    }
  }

  public func exchangeCode(
    _ exchange: ChatGPTCodeExchange
  ) async throws(ChatGPTSignInError) -> ChatGPTTokenResponse {
    exchanges.append(exchange)
    return try (exchangeHandler?(exchange) ?? exchangeResult).get()
  }

  public func refresh(
    refreshToken: String, clientID: String
  ) async throws(ChatGPTSignInError) -> ChatGPTTokenResponse {
    refreshedTokens.append(refreshToken)
    let index = min(refreshedTokens.count - 1, refreshResults.count - 1)
    let result = refreshResults.isEmpty ? .failure(.rejected) : refreshResults[index]
    if holdsRefresh {
      await withCheckedContinuation { gate.append($0) }
    }
    return try result.get()
  }

  public func revoke(refreshToken: String, clientID: String) async throws(ChatGPTSignInError) {
    revokedTokens.append(refreshToken)
    if let revokeError {
      throw revokeError
    }
  }

  public func signingKeys() async throws(ChatGPTSignInError) -> [ChatGPTSigningKey] {
    keys
  }
}

/// テスト用の `ChatGPTAccountStore`。メモリ上に保存し、失敗を注入できる。
public final class StubChatGPTAccountStore: ChatGPTAccountStore {
  private struct State {
    var record: ChatGPTAccountRecord?
    var loadFailure: ChatGPTAccountStoreError?
    var saveFailure: ChatGPTAccountStoreError?
    var saveCount = 0
  }

  private let state: Mutex<State>

  public init(record: ChatGPTAccountRecord? = nil) {
    state = Mutex(State(record: record))
  }

  /// 保存されている記録
  public var storedRecord: ChatGPTAccountRecord? { state.withLock { $0.record } }
  /// 保存した回数
  public var saveCount: Int { state.withLock { $0.saveCount } }

  public func setLoadFailure(_ error: ChatGPTAccountStoreError?) {
    state.withLock { $0.loadFailure = error }
  }

  public func setSaveFailure(_ error: ChatGPTAccountStoreError?) {
    state.withLock { $0.saveFailure = error }
  }

  public func load() throws(ChatGPTAccountStoreError) -> ChatGPTAccountRecord? {
    let result: Result<ChatGPTAccountRecord?, ChatGPTAccountStoreError> = state.withLock {
      if let failure = $0.loadFailure {
        return .failure(failure)
      }
      return .success($0.record)
    }
    return try result.get()
  }

  public func save(_ record: ChatGPTAccountRecord) throws(ChatGPTAccountStoreError) {
    let failure: ChatGPTAccountStoreError? = state.withLock {
      if let failure = $0.saveFailure {
        return failure
      }
      $0.record = record
      $0.saveCount += 1
      return nil
    }
    if let failure {
      throw failure
    }
  }
}

/// テスト用のループバックの待ち受けとシステムブラウザ。ネットワークもブラウザも使わない。
///
/// ブラウザで開いた認可要求の URL から `respond` でコールバックの URL を作り、待ち受けに届ける。
/// `respond` が `nil` を返すと、コールバックは届かない（上限時間・キャンセルの確認用）。
public final class StubChatGPTSignInFlow: ChatGPTLoopbackServer, ChatGPTBrowserOpening {
  public typealias Respond = @Sendable (_ authorizationURL: URL) -> URL?

  private struct State {
    var openedURLs: [URL] = []
    var continuation: AsyncStream<URL>.Continuation?
    var startCount = 0
    var stopCount = 0
  }

  public let port: UInt16
  private let respond: Respond
  private let opens: Bool
  private let startFailure: ChatGPTSignInError?
  private let state = Mutex(State())

  /// - Parameters:
  ///   - port: 待ち受けのポート
  ///   - opens: ブラウザを開けるか
  ///   - startFailure: 待ち受けを始めるときの失敗
  ///   - respond: 認可要求の URL からコールバックの URL を作る
  public init(
    port: UInt16 = 1455, opens: Bool = true, startFailure: ChatGPTSignInError? = nil,
    respond: @escaping Respond
  ) {
    self.port = port
    self.opens = opens
    self.startFailure = startFailure
    self.respond = respond
  }

  /// 開いた認可要求の URL（呼び出し順）
  public var openedURLs: [URL] { state.withLock { $0.openedURLs } }
  /// 待ち受けを始めた回数・やめた回数
  public var startCount: Int { state.withLock { $0.startCount } }
  public var stopCount: Int { state.withLock { $0.stopCount } }

  public func start() async throws(ChatGPTSignInError) -> any ChatGPTLoopbackListener {
    if let startFailure {
      throw startFailure
    }
    let (stream, continuation) = AsyncStream.makeStream(of: URL.self)
    state.withLock {
      $0.continuation = continuation
      $0.startCount += 1
    }
    return Listener(port: port, stream: stream, owner: self)
  }

  /// 待ち受けをやめる。待っているコールバックは `.cancelled` で終わる
  private func stopListening() {
    state.withLock {
      $0.stopCount += 1
      $0.continuation?.finish()
      $0.continuation = nil
    }
  }

  public func open(_ url: URL) async -> Bool {
    let continuation = state.withLock { state in
      state.openedURLs.append(url)
      return state.continuation
    }
    guard opens else { return false }
    if let callback = respond(url) {
      continuation?.yield(callback)
    }
    return true
  }

  /// 認可要求の `state` をそのまま返す、コールバックの URL を作る
  public static func callback(
    for authorizationURL: URL, code: String? = "test-code", clientID: String? = "oaiapp_test",
    error: String? = nil, state overriddenState: String? = nil
  ) -> URL {
    let request = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)
    let items = request?.queryItems ?? []
    let redirect = items.first { $0.name == "redirect_uri" }?.value.flatMap { URL(string: $0) }
    var components = URLComponents(
      url: redirect ?? ChatGPTSignIn.redirectURI(port: 1455), resolvingAgainstBaseURL: false)
    var query: [URLQueryItem] = []
    if let code { query.append(URLQueryItem(name: "code", value: code)) }
    if let error { query.append(URLQueryItem(name: "error", value: error)) }
    let originalState = items.first { $0.name == "state" }?.value
    query.append(URLQueryItem(name: "state", value: overriddenState ?? originalState))
    if let clientID { query.append(URLQueryItem(name: "client_id", value: clientID)) }
    components?.queryItems = query
    return components?.url ?? authorizationURL
  }

  private struct Listener: ChatGPTLoopbackListener {
    let port: UInt16
    let stream: AsyncStream<URL>
    let owner: StubChatGPTSignInFlow

    func callback() async throws(ChatGPTSignInError) -> URL {
      for await url in stream {
        return url
      }
      throw .cancelled
    }

    func stop() {
      owner.stopListening()
    }
  }
}
