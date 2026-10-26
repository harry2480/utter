import Synchronization

/// プロセス内で `STTWorkerService` を動かすテスト用の接続（4章, AC-10）。
///
/// 送ったメッセージを記録し、`simulateTermination(_:)` で Worker の異常終了（interruption / invalidation）を起こせる。
public final class StubSTTWorkerConnection: STTWorkerConnection {
  public let events: AsyncStream<STTWorkerConnectionEvent>
  public let service: STTWorkerService
  private let eventContinuation: AsyncStream<STTWorkerConnectionEvent>.Continuation
  private let requestContinuation: AsyncStream<STTWorkerRequest>.Continuation
  private let sent = Mutex<[STTWorkerRequest]>([])
  private let invalidated = Mutex(false)

  public init(service: STTWorkerService) {
    self.service = service
    let (events, eventContinuation) = AsyncStream.makeStream(of: STTWorkerConnectionEvent.self)
    let (requests, requestContinuation) = AsyncStream.makeStream(of: STTWorkerRequest.self)
    self.events = events
    self.eventContinuation = eventContinuation
    self.requestContinuation = requestContinuation
    Task {
      await service.run(incoming: requests) { eventContinuation.yield(.message($0)) }
    }
  }

  /// 送られたメッセージ（送った順）
  public var sentRequests: [STTWorkerRequest] {
    sent.withLock { $0 }
  }

  /// `invalidate()` が呼ばれたか
  public var isInvalidated: Bool {
    invalidated.withLock { $0 }
  }

  public func send(_ request: STTWorkerRequest) {
    sent.withLock { $0.append(request) }
    requestContinuation.yield(request)
  }

  public func invalidate() {
    invalidated.withLock { $0 = true }
    requestContinuation.finish()
    eventContinuation.finish()
  }

  /// Worker の異常終了を起こす。以後のメッセージは届かない
  public func simulateTermination(_ event: STTWorkerConnectionEvent = .interrupted) {
    requestContinuation.finish()
    eventContinuation.yield(event)
    eventContinuation.finish()
  }
}

/// `StubSTTWorkerConnection` を作るテスト用の接続元。接続のたびに新しい Worker（`STTWorkerService`）を作る
public final class StubSTTWorkerConnector: STTWorkerConnecting {
  private let makeService: @Sendable () -> STTWorkerService
  private let failure: STTWorkerConnectionError?
  private let made = Mutex<[StubSTTWorkerConnection]>([])

  /// - Parameters:
  ///   - failure: 指定すると `connect()` がこの失敗を投げる（Worker を起動できない状態）
  ///   - makeService: 接続のたびに呼び、新しい Worker とする
  public init(
    failure: STTWorkerConnectionError? = nil,
    makeService: @escaping @Sendable () -> STTWorkerService
  ) {
    self.failure = failure
    self.makeService = makeService
  }

  /// 作った接続（作った順）。数が Worker の起動回数にあたる
  public var connections: [StubSTTWorkerConnection] {
    made.withLock { $0 }
  }

  public func connect() throws(STTWorkerConnectionError) -> any STTWorkerConnection {
    if let failure {
      throw failure
    }
    let connection = StubSTTWorkerConnection(service: makeService())
    made.withLock { $0.append(connection) }
    return connection
  }
}
