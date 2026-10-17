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
  ///
  /// `now` は `ContinuousClock` で取得する。タイマーが期限より早く発火して `nil` が返った場合は、
  /// `recordingDeadline` でタイマーを設定し直す。
  @discardableResult
  public mutating func stopRecordingIfLimitReached(at now: ContinuousClock.Instant) -> SessionToken?
  {
    guard let deadline = recordingDeadline, now >= deadline else { return nil }
    return finishRecording(reason: .maxDurationReached)
  }

  /// 音声バッファの上限に達したため録音を停止して認識へ進む（REC-05）。録音中でなければ `nil` を返す。
  ///
  /// 音声を破棄せず、最大録音時間と同様に通常どおり処理を続ける。
  @discardableResult
  public mutating func stopRecordingAtBufferLimit() -> SessionToken? {
    guard phase == .recording else { return nil }
    return finishRecording(reason: .bufferLimitReached)
  }

  /// 録音中の割り込みを `policy` に従って処理する（iOS-PERF-03）。
  ///
  /// - 録音を止める割り込みで音声があれば、自動停止として認識へ進む（REC-05: 音声を破棄しない）
  /// - 処理できる音声がなければ、録音段階の失敗（`error(.recording)`）として表示する
  /// - 録音を止めない割り込み、または録音中以外では状態を変えない
  ///
  /// 停止・中止の原因は `activeSession.stopReason` に `.interrupted` として残る。
  /// - Parameters:
  ///   - interruption: OS の通知をアプリ側で変換した値
  ///   - capturedAudioDuration: その時点までに取得できた音声の長さ
  ///   - policy: 割り込みへの対応方針
  @discardableResult
  public mutating func handleInterruption(
    _ interruption: RecordingInterruption,
    capturedAudioDuration: Duration,
    policy: RecordingInterruptionPolicy
  ) -> RecordingInterruptionOutcome {
    guard phase == .recording else { return .ignored }
    switch policy.decision(for: interruption, capturedAudioDuration: capturedAudioDuration) {
    case .continueRecording:
      return .continued
    case .stopAndProcess(let cause):
      guard let token = finishRecording(reason: .interrupted(cause)) else { return .ignored }
      return .stopped(token)
    case .abort(let cause):
      advance(to: .error(.recording), stopReason: .interrupted(cause))
      return .aborted(cause)
    }
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
  /// 以降に届くそのセッションのイベントは `handle(_:)` で破棄される。
  /// `idle` と `inserting` では何もせず `nil` を返す。挿入は始まると取り消せないため、
  /// キャンセルを受け付けるのは録音〜整形中と失敗の表示中に限る（REC-01）。
  @discardableResult
  public mutating func cancel() -> SessionID? {
    guard let activeSession, phase != .inserting else { return nil }
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

/// 録音中の割り込みを処理した結果（iOS-PERF-03）。
public enum RecordingInterruptionOutcome: Hashable, Sendable {
  /// 録音を続ける
  case continued
  /// 録音を止めて認識へ進んだ。値は認識段階のトークン。アプリは録音を止め、取得済みの音声を認識へ渡す
  case stopped(SessionToken)
  /// 処理できる音声がないため録音を中止し、失敗の表示へ進んだ。アプリは録音を止めて理由を表示する
  case aborted(RecordingInterruptionCause)
  /// 録音中ではないため何もしなかった
  case ignored
}
