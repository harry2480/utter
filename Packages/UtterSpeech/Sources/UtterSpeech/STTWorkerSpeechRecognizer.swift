import Synchronization
import UtterCore

/// STT Worker の異常終了で失敗にしたセッション（7章, AC-10）。
public struct STTWorkerTermination: Hashable, Sendable {
  public let session: SessionID
  /// 再起動の回数制限の範囲内で、Worker をもう一度起動できるか。
  /// `false` のときは `resetRestartLimit()` まで認識を `failed(.engineFailed)` にする
  public let canRestart: Bool

  public init(session: SessionID, canRestart: Bool) {
    self.session = session
    self.canRestart = canRestart
  }
}

/// STT Worker への接続を `SpeechRecognizer` として見せるメインアプリ側のアダプター（4章, 7章, AC-10）。
///
/// 音声チャンクを `STTWorkerRequest.audio` で送り、Worker の `RecognitionEvent` をそのまま流す。
///
/// - エンジンが未選択（`engine == nil`）なら Worker を起動せず、`failed(.modelUnavailable)` にする（既定のエンジンは
///   Phase 0 の判定待ちで持たない）
/// - Worker は最初の認識で起動する。待機中には起動しない（6章「待機中は STT 停止」）
/// - 認識中に Worker が異常終了したら（接続の interruption / invalidation）、そのセッションを `failed(.engineFailed)` にして
///   終え、`onTermination` で知らせる。一時音声からの再処理（`RecordedAudio` で同じ `SessionID` のまま認識し直す）はそこから始める。
///   `onTermination` は受け手が `failed(.engineFailed)` を受け取った後に呼ぶため、受け手は失敗を受けても再処理が終わるまで
///   録音した音声を手放さない。Worker を起動できなかった（接続できない）場合は回数に数えるが、`onTermination` は呼ばない
/// - 再起動は次の認識で接続を作り直して行う。認識中の異常終了が `restartLimit` 回を超えて続いたら、それ以上 Worker を起動しない。
///   Worker が終端イベントを返したら回数を 0 に戻す
/// - 同時に認識するのは1セッションまで。認識中に別のセッションを始めたら `failed(.resourceLimited)` にする
/// - 音声・認識テキストはログに出さない
public actor STTWorkerSpeechRecognizer: SpeechRecognizer {
  public enum State: Hashable, Sendable {
    /// Worker に接続していない（未起動、または終了後）
    case idle
    case connected
    /// 異常終了が続いたため、Worker を起動しない
    case restartLimitReached
  }

  /// 異常終了の後に Worker を再起動してよい回数の既定値（仮置き。Phase 0 の安定性検証で見直す）。
  /// Mac 全体の安定性を優先し（11章 判断原則）、異常終了を繰り返す Worker を起動し続けない
  public static let defaultRestartLimit = 2

  /// 受け手がストリームを破棄したか。破棄から `cancel` が actor に届くまでの間に次のセッションが始まっても、
  /// 破棄済みのセッションを先に止められるよう、同期的に記録する
  private final class ConsumerDrop: Sendable {
    private let dropped = Mutex(false)

    var isDropped: Bool {
      dropped.withLock { $0 }
    }

    func markDropped() {
      dropped.withLock { $0 = true }
    }
  }

  private struct ActiveSession {
    let session: SessionID
    let continuation: AsyncStream<RecognitionEvent>.Continuation
    let pump: Task<Void, Never>
    let drop: ConsumerDrop
    var nextSequence: UInt64 = 0
  }

  public nonisolated let engine: STTEngineKind?
  public nonisolated let restartLimit: Int
  private let connector: any STTWorkerConnecting
  private let onTermination: (@Sendable (STTWorkerTermination) async -> Void)?

  public private(set) var state: State = .idle
  /// 認識中の異常終了が続いた回数
  public private(set) var consecutiveFailures = 0
  private var connection: (any STTWorkerConnection)?
  /// 古い接続からのイベントを見分ける番号。接続のたびに増やす
  private var connectionGeneration: UInt64 = 0
  private var active: ActiveSession?
  private var resources: STTWorkerResources?
  /// 最後に認識中の異常終了で失敗にしたセッション
  private var lastTermination: STTWorkerTermination?

  /// - Parameters:
  ///   - engine: 使うエンジン。既定値はない。`nil` なら Worker を起動しない
  ///   - connector: Worker への接続。本番は Apps/macOS の XPC 実装
  ///   - restartLimit: 異常終了の後に再起動してよい回数。0 以下なら一度の異常終了で止める
  ///   - onTermination: 認識中の異常終了を知らせる。一時音声からの再処理の差し込み口
  public init(
    engine: STTEngineKind?,
    connector: any STTWorkerConnecting,
    restartLimit: Int = defaultRestartLimit,
    onTermination: (@Sendable (STTWorkerTermination) async -> Void)? = nil
  ) {
    self.engine = engine
    self.connector = connector
    self.restartLimit = max(0, restartLimit)
    self.onTermination = onTermination
  }

  public nonisolated func recognize(
    _ audio: AsyncStream<AudioChunk>, session: SessionID
  ) -> AsyncStream<RecognitionEvent> {
    // 終端イベントを落とさないよう、バッファは無制限にする（イベントは Worker から届いた分だけ）
    let (stream, continuation) = AsyncStream.makeStream(of: RecognitionEvent.self)
    let drop = ConsumerDrop()
    let begin = Task {
      await self.begin(audio, session: session, continuation: continuation, drop: drop)
    }
    continuation.onTermination = { reason in
      // 受け手がストリームを破棄したときだけ、Worker の認識を止める
      guard case .cancelled = reason else { return }
      drop.markDropped()
      Task {
        await begin.value
        await self.cancel(session)
      }
    }
    return stream
  }

  /// モデル保持の設定と端末の状態を Worker へ送る（6章, AC-11）。接続し直したときも送り直す
  public func updateResources(_ resources: STTWorkerResources) {
    self.resources = resources
    connection?.send(.updateResources(resources))
  }

  /// `session` が認識中の Worker の異常終了で失敗になったか（7章, AC-10）。なっていれば、そのときの `STTWorkerTermination`。
  ///
  /// 受け手が `failed(.engineFailed)` を受け取った時点で記録済みのため、受け手はその後に呼べば、
  /// 異常終了による失敗か（起動の失敗・回数制限・Worker の報告した失敗ではないか）を順序に依らずに見分けられる。
  /// `onTermination` は失敗を流した後に呼ぶため、受け手がそれを待つと、異常終了でない失敗では待ち続けてしまう。
  /// 記録するのは最後の1件だけで、次の異常終了で置き換わる
  public func termination(of session: SessionID) -> STTWorkerTermination? {
    lastTermination?.session == session ? lastTermination : nil
  }

  /// 再起動の回数制限を解除する（利用者が再試行を選んだときなど）
  public func resetRestartLimit() {
    consecutiveFailures = 0
    if state == .restartLimitReached {
      state = .idle
    }
  }

  /// Worker への接続を閉じる（アプリの終了時など）。認識中のセッションは `failed(.engineFailed)` にする。
  /// 異常終了としては数えない
  public func disconnect() {
    connectionGeneration &+= 1
    connection?.invalidate()
    connection = nil
    if state == .connected {
      state = .idle
    }
    finishActive(with: .failed(.engineFailed))
  }

  private func begin(
    _ audio: AsyncStream<AudioChunk>, session: SessionID,
    continuation: AsyncStream<RecognitionEvent>.Continuation, drop: ConsumerDrop
  ) async {
    func fail(_ error: SpeechRecognitionError) {
      continuation.yield(RecognitionEvent(sessionID: session, sequence: 0, kind: .failed(error)))
      continuation.finish()
    }
    guard let engine else {
      fail(.modelUnavailable)
      return
    }
    guard state != .restartLimitReached else {
      fail(.engineFailed)
      return
    }
    // 破棄済みで止める前のセッションは、ここで先に止める（Worker にも `cancel` を `start` より先に送る）
    if let active, active.drop.isDropped {
      cancel(active.session)
    }
    guard active == nil else {
      fail(.resourceLimited)
      return
    }
    let connection: any STTWorkerConnection
    do {
      connection = try connect()
    } catch {
      // 起動できなかったときも、起動を繰り返さないよう回数に数える。直る見込みが分からないため、
      // 再処理の通知（onTermination）は送らない
      fail(.engineFailed)
      recordFailure()
      return
    }

    connection.send(.start(session: session, engine: engine))
    let pump = Task {
      for await chunk in audio {
        connection.send(.audio(session: session, chunk: chunk))
      }
      // 終端イベントを受けて止めた（キャンセル）なら、録音の終了は送らない
      if !Task.isCancelled {
        connection.send(.finishAudio(session: session))
      }
    }
    active = ActiveSession(session: session, continuation: continuation, pump: pump, drop: drop)
  }

  private func connect() throws(STTWorkerConnectionError) -> any STTWorkerConnection {
    if let connection {
      return connection
    }
    let connection = try connector.connect()
    connectionGeneration &+= 1
    let generation = connectionGeneration
    self.connection = connection
    state = .connected
    Task {
      for await event in connection.events {
        await self.handle(event, generation: generation)
      }
      // 終了のイベントなしに終わった場合も、接続が切れたものとして扱う
      await self.connectionDidEnd(generation: generation)
    }
    if let resources {
      connection.send(.updateResources(resources))
    }
    return connection
  }

  private func handle(_ event: STTWorkerConnectionEvent, generation: UInt64) async {
    guard generation == connectionGeneration else { return }
    switch event {
    case .message(.event(let event)):
      guard var active, active.session == event.sessionID else { return }
      if event.kind.isTerminal {
        // Worker は動いている。異常終了の回数を戻す
        consecutiveFailures = 0
        self.active = nil
        active.pump.cancel()
        active.continuation.yield(event)
        active.continuation.finish()
      } else {
        active.nextSequence = event.sequence &+ 1
        self.active = active
        active.continuation.yield(event)
      }
    case .interrupted, .invalidated:
      await connectionDidEnd(generation: generation)
    }
  }

  private func connectionDidEnd(generation: UInt64) async {
    guard generation == connectionGeneration, let connection else { return }
    connectionGeneration &+= 1
    connection.invalidate()
    self.connection = nil
    state = .idle
    // 待機中の終了は数えない（OS がアイドルの Worker を終了させることがある）
    guard let session = active?.session else { return }
    // 受け手が `failed(.engineFailed)` を受け取った時点で `termination(of:)` が答えられるよう、先に記録する
    let termination = STTWorkerTermination(session: session, canRestart: recordFailure())
    lastTermination = termination
    finishActive(with: .failed(.engineFailed))
    await onTermination?(termination)
  }

  /// 認識中のセッションを終端イベントで終える
  private func finishActive(with kind: RecognitionEvent.Kind) {
    guard let active else { return }
    self.active = nil
    active.pump.cancel()
    active.continuation.yield(
      RecognitionEvent(sessionID: active.session, sequence: active.nextSequence, kind: kind))
    active.continuation.finish()
  }

  private func cancel(_ session: SessionID) {
    guard let active, active.session == session else { return }
    self.active = nil
    active.pump.cancel()
    connection?.send(.cancel(session: session))
  }

  /// 異常終了を数え、まだ再起動してよいかを返す
  @discardableResult
  private func recordFailure() -> Bool {
    consecutiveFailures += 1
    let canRestart = consecutiveFailures <= restartLimit
    if !canRestart {
      state = .restartLimitReached
    }
    return canRestart
  }
}
