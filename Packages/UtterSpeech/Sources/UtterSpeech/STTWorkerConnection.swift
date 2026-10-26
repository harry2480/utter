/// STT Worker への接続で起きること（4章 STT Worker, AC-10）。
public enum STTWorkerConnectionEvent: Hashable, Sendable {
  /// Worker からのメッセージ
  case message(STTWorkerResponse)
  /// Worker が異常終了した（クラッシュ・OS による強制終了など）。接続を作り直せば再起動できる
  case interrupted
  /// 接続が無効になった（Worker が見つからない、接続が取り消されたなど）
  case invalidated
}

/// メインアプリから STT Worker への接続。本番は Apps/macOS の XPC 実装、テストは `StubSTTWorkerConnection`。
///
/// `events` は `interrupted` か `invalidated` を最後に流して終える。終わった接続は使い回さず、
/// `STTWorkerConnecting.connect()` で作り直す。
public protocol STTWorkerConnection: Sendable {
  /// Worker からのメッセージと接続の終了。届いた順に流す
  var events: AsyncStream<STTWorkerConnectionEvent> { get }

  /// メッセージを送る。送れなかったときは `events` に終了を流す
  func send(_ request: STTWorkerRequest)

  /// 接続を閉じる。`events` は終わる（終了のイベントは流しても流さなくてもよい）
  func invalidate()
}

/// STT Worker への接続を作る。接続を作ることが Worker の起動にあたる
public protocol STTWorkerConnecting: Sendable {
  func connect() throws(STTWorkerConnectionError) -> any STTWorkerConnection
}

public enum STTWorkerConnectionError: Error, Hashable, Sendable {
  /// Worker に接続できない（アプリに組み込まれていない、起動できないなど）
  case unavailable
}
