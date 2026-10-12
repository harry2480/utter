/// 音声入力セッションの状態機械（REC-05, REC-06）。
///
/// `idle → recording → recognizing → refining → inserting → idle` の遷移だけを受け付け、
/// 同時に1セッションのみを扱う。時刻は引数で受け取り、タイマーなどの OS 実装は持たない。
/// 値型なので、利用側は `@MainActor` や `actor` に隔離して保持する。
public struct SessionStateMachine: Sendable {
  public let configuration: SessionConfiguration
  public private(set) var phase: SessionPhase = .idle
  /// 進行中（失敗の表示中を含む）のセッション。`idle` では `nil`。
  public private(set) var activeSession: ActiveSession?

  private let makeSessionID: @Sendable () -> SessionID

  public init(
    configuration: SessionConfiguration = SessionConfiguration(),
    makeSessionID: @escaping @Sendable () -> SessionID = { SessionID() }
  ) {
    self.configuration = configuration
    self.makeSessionID = makeSessionID
  }

  /// 現在の段階で非同期処理を依頼するときに添えるトークン。
  public var currentToken: SessionToken? {
    activeSession?.token
  }

  /// 録音中なら最大録音時間に達する時刻（REC-05）。アプリはこの時刻にタイマーを設定する。
  public var recordingDeadline: ContinuousClock.Instant? {
    guard phase == .recording, let activeSession else { return nil }
    return activeSession.startedAt.advanced(by: configuration.maxRecordingDuration)
  }

  /// 開始操作を処理する（REC-06）。
  ///
  /// - `idle`: 新しいセッションで録音を開始する
  /// - `recording`: 2回目の操作として録音を停止する（REC-01）
  /// - それ以外（処理中・失敗の表示中）: 無視する
  @discardableResult
  public mutating func start(at now: ContinuousClock.Instant) -> SessionStartOutcome {
    switch phase {
    case .idle:
      let session = ActiveSession(id: makeSessionID(), sequence: 0, startedAt: now, stopReason: nil)
      activeSession = session
      phase = .recording
      return .started(session.token)
    case .recording:
      guard let token = stopRecording(at: now) else { return .ignored }
      return .stopped(token)
    case .recognizing, .refining, .inserting, .error:
      return .ignored
    }
  }

  /// 録音を停止して認識へ進む。録音中でなければ何もせず `nil` を返す。
  ///
  /// 最大録音時間を過ぎてから呼ばれた場合は自動停止として扱う（REC-05）。
  @discardableResult
  public mutating func stopRecording(at now: ContinuousClock.Instant) -> SessionToken? {
    guard let deadline = recordingDeadline else { return nil }
    return finishRecording(reason: now >= deadline ? .maxDurationReached : .manual)
  }

  /// 最大録音時間に達していれば自動停止して認識へ進む（REC-05）。停止しなければ `nil` を返す。
  @discardableResult
  public mutating func stopRecordingIfLimitReached(at now: ContinuousClock.Instant) -> SessionToken?
  {
    guard let deadline = recordingDeadline, now >= deadline else { return nil }
    return finishRecording(reason: .maxDurationReached)
  }

  /// 非同期処理の結果を反映する。
  ///
  /// 現在のトークンと一致しないイベントは遅延イベントとして破棄する。
  /// 一致するが現在の状態で許可されていない遷移は `SessionTransitionError` を投げ、状態は変えない。
  public mutating func handle(
    _ event: SessionEvent
  ) throws(SessionTransitionError) -> SessionEventOutcome {
    guard let activeSession, activeSession.id == event.token.sessionID else {
      return .discarded(.inactiveSession)
    }
    guard activeSession.sequence == event.token.sequence else {
      return .discarded(.sequenceMismatch)
    }

    switch (phase, event.kind) {
    case (.recognizing, .recognitionCompleted):
      advance(to: .refining)
    case (.refining, .refinementCompleted):
      advance(to: .inserting)
    case (.inserting, .insertionCompleted):
      reset()
    case (.recording, .failed):
      advance(to: .error(.recording))
    case (.recognizing, .failed):
      advance(to: .error(.recognition))
    case (.refining, .failed):
      advance(to: .error(.refinement))
    case (.inserting, .failed):
      advance(to: .error(.insertion))
    default:
      throw .invalidTransition(from: phase, event: event.kind)
    }
    return .applied(phase)
  }

  /// Esc 相当のキャンセル。進行中のセッションを破棄して `idle` に戻り、破棄したセッションの ID を返す。
  ///
  /// 以降に届くそのセッションのイベントは `handle(_:)` で破棄される。`idle` では何もしない。
  @discardableResult
  public mutating func cancel() -> SessionID? {
    guard let activeSession else { return nil }
    reset()
    return activeSession.id
  }

  /// 失敗の表示を終えて `idle` に戻る。`error` 以外では何もせず `false` を返す。
  @discardableResult
  public mutating func dismissError() -> Bool {
    guard case .error = phase else { return false }
    reset()
    return true
  }

  private mutating func finishRecording(reason: RecordingStopReason) -> SessionToken? {
    advance(to: .recognizing, stopReason: reason)
    return currentToken
  }

  private mutating func advance(to next: SessionPhase, stopReason: RecordingStopReason? = nil) {
    activeSession = activeSession?.advanced(stopReason: stopReason)
    phase = next
  }

  private mutating func reset() {
    activeSession = nil
    phase = .idle
  }
}

/// 開始操作を処理した結果。
public enum SessionStartOutcome: Hashable, Sendable {
  /// 録音を開始した。値は録音段階のトークン
  case started(SessionToken)
  /// 録音中だったため停止した。値は認識段階のトークン
  case stopped(SessionToken)
  /// 処理中のため無視した
  case ignored
}
