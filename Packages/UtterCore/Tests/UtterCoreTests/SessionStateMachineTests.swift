import Synchronization
import Testing

@testable import UtterCore

/// 処理中（recording 以外の非 idle）の状態
enum ProcessingPhase: CaseIterable, Sendable {
  case recognizing
  case refining
  case inserting
  case error
}

struct SessionStateMachineTests {
  let t0 = ContinuousClock.now

  @Test("REC-06: 待機→録音→認識→整形→挿入→待機 を一巡する")
  func completesFullCycle() throws {
    var machine = SessionStateMachine()
    #expect(machine.phase == .idle)
    #expect(machine.activeSession == nil)

    guard case .started = machine.start(at: t0) else {
      Issue.record("録音を開始できなかった")
      return
    }
    #expect(machine.phase == .recording)

    machine.stopRecording(at: t0 + .seconds(10))
    #expect(machine.phase == .recognizing)
    #expect(machine.activeSession?.stopReason == .manual)

    let recognized = try machine.handle(event(machine, .recognitionCompleted))
    #expect(recognized == .applied(.refining))
    let refined = try machine.handle(event(machine, .refinementCompleted))
    #expect(refined == .applied(.inserting))
    let inserted = try machine.handle(event(machine, .insertionCompleted))
    #expect(inserted == .applied(.idle))
    #expect(machine.activeSession == nil)
  }

  @Test("REC-06: 状態が進むたびに順序番号が増える")
  func incrementsSequenceOnTransition() throws {
    var machine = SessionStateMachine()
    machine.start(at: t0)
    let recording = try #require(machine.currentToken)
    machine.stopRecording(at: t0)
    let recognizing = try #require(machine.currentToken)

    #expect(recognizing.sessionID == recording.sessionID)
    #expect(recognizing.sequence == recording.sequence + 1)
  }

  @Test("REC-06: 録音中の開始操作は録音を停止する")
  func startWhileRecordingStops() throws {
    var machine = SessionStateMachine()
    machine.start(at: t0)
    let sessionID = try #require(machine.activeSession?.id)

    let outcome = machine.start(at: t0 + .seconds(5))

    #expect(machine.phase == .recognizing)
    #expect(outcome == .stopped(try #require(machine.currentToken)))
    #expect(machine.activeSession?.id == sessionID)
    #expect(machine.activeSession?.stopReason == .manual)
  }

  @Test("REC-06: 処理中の開始操作は無視される", arguments: ProcessingPhase.allCases)
  func ignoresStartWhileProcessing(_ processing: ProcessingPhase) throws {
    var machine = try machine(in: processing)
    let before = machine.phase
    let token = machine.currentToken

    let outcome = machine.start(at: t0 + .seconds(1))

    #expect(outcome == .ignored)
    #expect(machine.phase == before)
    #expect(machine.currentToken == token)
  }

  @Test("REC-06: 連打しても同時に1セッションのみ")
  func repeatedStartKeepsSingleSession() {
    let ids = IDSequence()
    var machine = SessionStateMachine(makeSessionID: ids.next)

    for offset in 0..<10 {
      machine.start(at: t0 + .milliseconds(offset * 10))
    }

    // 1回目で開始、2回目で停止し、以降は認識中のため無視される
    #expect(machine.phase == .recognizing)
    #expect(ids.count == 1)
  }

  @Test("REC-06: 新しいセッションは別のIDを持つ")
  func newSessionHasNewID() {
    var machine = SessionStateMachine()
    machine.start(at: t0)
    let first = machine.cancel()
    machine.start(at: t0)

    #expect(first != nil)
    #expect(machine.activeSession?.id != first)
  }

  @Test(
    "REC-06: 許可されていない遷移は拒否され、状態は変わらない",
    arguments: [ProcessingPhase?.none] + ProcessingPhase.allCases.map(Optional.some),
    [SessionEvent.Kind.recognitionCompleted, .refinementCompleted, .insertionCompleted, .failed]
  )
  func rejectsInvalidTransition(_ processing: ProcessingPhase?, _ kind: SessionEvent.Kind) throws {
    let allowed: [ProcessingPhase?: Set<SessionEvent.Kind>] = [
      .none: [.failed],
      .recognizing: [.recognitionCompleted, .failed],
      .refining: [.refinementCompleted, .failed],
      .inserting: [.insertionCompleted, .failed],
      .error: [],
    ]
    guard allowed[processing]?.contains(kind) == false else { return }

    var machine = try machine(in: processing)
    let before = machine.phase
    let token = machine.currentToken
    let invalid = try event(machine, kind)

    #expect(throws: SessionTransitionError.invalidTransition(from: before, event: kind)) {
      try machine.handle(invalid)
    }
    #expect(machine.phase == before)
    #expect(machine.currentToken == token)
  }

  @Test("REC-06: Esc 相当のキャンセルで待機に戻る", arguments: [ProcessingPhase.recognizing, .refining, .error])
  func cancelReturnsToIdle(_ processing: ProcessingPhase) throws {
    var machine = try machine(in: processing)
    let sessionID = try #require(machine.activeSession?.id)

    let cancelled = machine.cancel()

    #expect(cancelled == sessionID)
    #expect(machine.phase == .idle)
    #expect(machine.activeSession == nil)
  }

  @Test("REC-06: 録音中のキャンセルで待機に戻る")
  func cancelWhileRecording() throws {
    var machine = SessionStateMachine()
    machine.start(at: t0)

    let cancelled = machine.cancel()

    #expect(cancelled != nil)
    #expect(machine.phase == .idle)
    #expect(machine.recordingDeadline == nil)
  }

  @Test("REC-01: 挿入中のキャンセルは受け付けない")
  func cancelWhileInsertingDoesNothing() throws {
    var machine = try machine(in: .inserting)
    let token = machine.currentToken

    let cancelled = machine.cancel()

    #expect(cancelled == nil)
    #expect(machine.phase == .inserting)
    #expect(machine.currentToken == token)
  }

  @Test("REC-06: 待機中のキャンセルは何もしない")
  func cancelWhileIdleDoesNothing() {
    var machine = SessionStateMachine()

    let cancelled = machine.cancel()

    #expect(cancelled == nil)
    #expect(machine.phase == .idle)
  }

  @Test("REC-06: キャンセル済みセッションの遅延イベントは破棄される")
  func discardsEventsOfCancelledSession() throws {
    var machine = SessionStateMachine()
    machine.start(at: t0)
    machine.stopRecording(at: t0)
    let stale = try #require(machine.currentToken)
    machine.cancel()

    let whileIdle = try machine.handle(SessionEvent(token: stale, kind: .recognitionCompleted))
    #expect(whileIdle == .discarded(.inactiveSession))
    #expect(machine.phase == .idle)

    // 次のセッションが同じ段階にいても、前のセッションのイベントは反映しない
    machine.start(at: t0)
    machine.stopRecording(at: t0)
    let completed = try machine.handle(SessionEvent(token: stale, kind: .recognitionCompleted))
    #expect(completed == .discarded(.inactiveSession))
    let failed = try machine.handle(SessionEvent(token: stale, kind: .failed))
    #expect(failed == .discarded(.inactiveSession))
    #expect(machine.phase == .recognizing)
  }

  @Test("REC-06: 過ぎた段階の遅延イベントは順序番号で破棄される")
  func discardsEventsOfPastStage() throws {
    var machine = SessionStateMachine()
    machine.start(at: t0)
    let recording = try #require(machine.currentToken)
    machine.stopRecording(at: t0)
    let recognizing = try #require(machine.currentToken)
    _ = try machine.handle(SessionEvent(token: recognizing, kind: .recognitionCompleted))

    let lateFailure = try machine.handle(SessionEvent(token: recording, kind: .failed))
    #expect(lateFailure == .discarded(.sequenceMismatch))
    let duplicate = try machine.handle(
      SessionEvent(token: recognizing, kind: .recognitionCompleted))
    #expect(duplicate == .discarded(.sequenceMismatch))
    #expect(machine.phase == .refining)
  }

  @Test("REC-06: 未来の順序番号のイベントは破棄される")
  func discardsEventsWithFutureSequence() throws {
    var machine = SessionStateMachine()
    machine.start(at: t0)
    let current = try #require(machine.currentToken)
    let future = SessionToken(sessionID: current.sessionID, sequence: current.sequence + 1)

    let outcome = try machine.handle(SessionEvent(token: future, kind: .failed))

    #expect(outcome == .discarded(.sequenceMismatch))
    #expect(machine.phase == .recording)
  }

  @Test("REC-06: 失敗の表示中に失敗した段階の遅延イベントは破棄される")
  func discardsEventsOfFailedStage() throws {
    var machine = try machine(in: .recognizing)
    let recognizing = try #require(machine.currentToken)
    _ = try machine.handle(SessionEvent(token: recognizing, kind: .failed))

    let late = try machine.handle(SessionEvent(token: recognizing, kind: .recognitionCompleted))

    #expect(late == .discarded(.sequenceMismatch))
    #expect(machine.phase == .error(.recognition))
  }

  @Test(
    "REC-06: 失敗すると error を経て待機に戻る",
    arguments: [
      (ProcessingPhase?.none, SessionFailure.recording),
      (.recognizing, .recognition),
      (.refining, .refinement),
      (.inserting, .insertion),
    ]
  )
  func failureGoesThroughErrorToIdle(_ processing: ProcessingPhase?, _ failure: SessionFailure)
    throws
  {
    var machine = try self.machine(in: processing)

    let failed = try machine.handle(event(machine, .failed))
    #expect(failed == .applied(.error(failure)))
    let restart = machine.start(at: t0)
    #expect(restart == .ignored)

    let dismissed = machine.dismissError()
    #expect(dismissed)
    #expect(machine.phase == .idle)
    #expect(machine.activeSession == nil)
  }

  @Test("REC-06: error 以外では失敗表示の終了は何もしない")
  func dismissErrorOutsideErrorDoesNothing() throws {
    var machine = SessionStateMachine()
    let whileIdle = machine.dismissError()
    #expect(!whileIdle)

    machine.start(at: t0)
    let whileRecording = machine.dismissError()
    #expect(!whileRecording)
    #expect(machine.phase == .recording)
  }

  @Test("REC-06: 録音中でなければ停止操作は何もしない")
  func stopOutsideRecordingDoesNothing() throws {
    var machine = SessionStateMachine()
    let whileIdle = machine.stopRecording(at: t0)
    #expect(whileIdle == nil)
    #expect(machine.phase == .idle)

    machine = try self.machine(in: .refining)
    let whileRefining = machine.stopRecording(at: t0)
    #expect(whileRefining == nil)
    #expect(machine.phase == .refining)
  }

  // MARK: - REC-05

  @Test("REC-05: 最大録音時間に達したら自動停止して認識へ進む")
  func stopsAtMaxRecordingDuration() throws {
    var machine = SessionStateMachine()
    machine.start(at: t0)
    #expect(machine.recordingDeadline == t0 + .seconds(300))

    let token = machine.stopRecordingIfLimitReached(at: t0 + .seconds(300))

    #expect(token != nil)
    #expect(token == machine.currentToken)
    #expect(machine.phase == .recognizing)
    #expect(machine.activeSession?.stopReason == .maxDurationReached)
    #expect(machine.recordingDeadline == nil)
  }

  @Test("REC-05: 最大録音時間の前は自動停止しない")
  func doesNotStopBeforeMaxRecordingDuration() {
    var machine = SessionStateMachine()
    machine.start(at: t0)

    let token = machine.stopRecordingIfLimitReached(at: t0 + .seconds(299))

    #expect(token == nil)
    #expect(machine.phase == .recording)
    #expect(machine.activeSession?.stopReason == nil)
  }

  @Test("REC-05: 最大録音時間は設定で変更できる")
  func usesConfiguredMaxRecordingDuration() throws {
    var machine = SessionStateMachine(
      configuration: try SessionConfiguration(maxRecordingDuration: .seconds(30)))
    machine.start(at: t0)

    let beforeLimit = machine.stopRecordingIfLimitReached(at: t0 + .seconds(29))
    #expect(beforeLimit == nil)
    let atLimit = machine.stopRecordingIfLimitReached(at: t0 + .seconds(30))
    #expect(atLimit != nil)
    #expect(machine.activeSession?.stopReason == .maxDurationReached)
  }

  @Test("REC-05: 上限を過ぎてからの停止操作は自動停止として扱う")
  func lateManualStopIsTreatedAsLimit() throws {
    var machine = SessionStateMachine()
    machine.start(at: t0)

    let outcome = machine.start(at: t0 + .seconds(301))

    #expect(outcome == .stopped(try #require(machine.currentToken)))
    #expect(machine.phase == .recognizing)
    #expect(machine.activeSession?.stopReason == .maxDurationReached)
  }

  @Test("REC-05: ちょうど上限の時刻の停止操作は自動停止として扱う")
  func manualStopAtDeadlineIsTreatedAsLimit() {
    var machine = SessionStateMachine()
    machine.start(at: t0)

    machine.stopRecording(at: t0 + .seconds(300))

    #expect(machine.activeSession?.stopReason == .maxDurationReached)
  }

  @Test("REC-05: 音声バッファの上限で録音を停止して認識へ進む")
  func stopsAtBufferLimit() {
    var machine = SessionStateMachine()
    machine.start(at: t0)

    let token = machine.stopRecordingAtBufferLimit()

    #expect(token != nil)
    #expect(token == machine.currentToken)
    #expect(machine.phase == .recognizing)
    #expect(machine.activeSession?.stopReason == .bufferLimitReached)
  }

  @Test("REC-05: 録音中以外ではバッファ上限による停止は何もしない")
  func bufferLimitOutsideRecordingDoesNothing() throws {
    var machine = SessionStateMachine()
    let whileIdle = machine.stopRecordingAtBufferLimit()
    #expect(whileIdle == nil)

    machine = try self.machine(in: .refining)
    let whileRefining = machine.stopRecordingAtBufferLimit()
    #expect(whileRefining == nil)
    #expect(machine.phase == .refining)
  }

  @Test("REC-05: 録音中以外では自動停止しない", arguments: ProcessingPhase.allCases)
  func limitCheckOutsideRecordingDoesNothing(_ processing: ProcessingPhase) throws {
    var machine = try machine(in: processing)
    let before = machine.phase

    let token = machine.stopRecordingIfLimitReached(at: t0 + .seconds(3600))

    #expect(token == nil)
    #expect(machine.phase == before)
  }

  @Test("REC-05: 自動停止の理由は後続の段階でも保持される")
  func keepsStopReasonAcrossStages() throws {
    var machine = SessionStateMachine()
    machine.start(at: t0)
    machine.stopRecordingIfLimitReached(at: t0 + .seconds(300))
    _ = try machine.handle(event(machine, .recognitionCompleted))

    #expect(machine.phase == .refining)
    #expect(machine.activeSession?.stopReason == .maxDurationReached)
  }

  // MARK: - Helpers

  /// `nil` は録音中
  private func machine(in processing: ProcessingPhase?) throws -> SessionStateMachine {
    var machine = SessionStateMachine()
    machine.start(at: t0)
    guard let processing else { return machine }
    machine.stopRecording(at: t0)
    switch processing {
    case .recognizing:
      break
    case .refining:
      _ = try machine.handle(event(machine, .recognitionCompleted))
    case .inserting:
      _ = try machine.handle(event(machine, .recognitionCompleted))
      _ = try machine.handle(event(machine, .refinementCompleted))
    case .error:
      _ = try machine.handle(event(machine, .failed))
    }
    return machine
  }

  private func event(_ machine: SessionStateMachine, _ kind: SessionEvent.Kind) throws
    -> SessionEvent
  {
    SessionEvent(token: try #require(machine.currentToken), kind: kind)
  }
}

/// 生成した ID の数を数える ID 生成器
private final class IDSequence: Sendable {
  private let generated = Mutex(0)

  var count: Int { generated.withLock { $0 } }

  var next: @Sendable () -> SessionID {
    { [self] in
      generated.withLock { $0 += 1 }
      return SessionID()
    }
  }
}
