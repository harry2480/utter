import Synchronization

/// テスト用の `APIKeyStore`。メモリ上に保存し、操作ごとに失敗を注入できる。
public final class StubAPIKeyStore: APIKeyStore {
  /// 失敗を注入する操作
  public enum Operation: Hashable, Sendable, CaseIterable {
    case load
    case save
    case delete
  }

  private struct State {
    var key: APIKey?
    var failures: [Operation: APIKeyStoreError] = [:]
    var calls: [Operation] = []
  }

  private let state: Mutex<State>

  public init(key: APIKey? = nil) {
    state = Mutex(State(key: key))
  }

  /// 保存されているキー
  public var storedKey: APIKey? { state.withLock { $0.key } }
  /// 呼び出された操作（呼び出し順）
  public var calls: [Operation] { state.withLock { $0.calls } }

  /// 指定した操作で `error` を投げるようにする。`nil` で解除する。
  public func setFailure(_ error: APIKeyStoreError?, for operation: Operation) {
    state.withLock { $0.failures[operation] = error }
  }

  public func load() throws(APIKeyStoreError) -> APIKey? {
    try perform(.load) { $0.key }
  }

  public func save(_ key: APIKey) throws(APIKeyStoreError) {
    try perform(.save) { $0.key = key }
  }

  public func delete() throws(APIKeyStoreError) {
    try perform(.delete) { $0.key = nil }
  }

  private func perform<T>(_ operation: Operation, _ body: (inout State) -> T)
    throws(APIKeyStoreError) -> T
  {
    let result: Result<T, APIKeyStoreError> = state.withLock { state in
      state.calls.append(operation)
      if let failure = state.failures[operation] {
        return .failure(failure)
      }
      return .success(body(&state))
    }
    return try result.get()
  }
}
