import Foundation
import Synchronization
import Testing
import UtterCore

@testable import UtterPersistence

/// 閉じても録音を続ける設定（iOS-06, #267）での、キーボードの閉じ方と引き継ぎ。
@MainActor
struct KeyboardStandbyKeepRecordingTests {
  private let directory = TemporaryDirectory()
  private let base = Date(timeIntervalSince1970: 1_800_000_000)

  final class Clock: Sendable {
    private let value: Mutex<Date>
    init(_ start: Date) { value = Mutex(start) }
    var now: Date { value.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { value.withLock { $0 = $0.addingTimeInterval(seconds) } }
  }

  final class CountingInserter: KeyboardStandbyInserting {
    private let calls = Mutex<[SessionID]>([])
    var insertedSessions: [SessionID] { calls.withLock { $0 } }
    func insertResult(sessionID: SessionID) async throws -> SharedResultInsertionOutcome {
      calls.withLock { $0.append(sessionID) }
      return .inserted
    }
  }

  /// 停止の合図の書き込みを、開くまで止める（停止を書いている途中に閉じる競合を試す）
  final class StopGate: Sendable {
    private let continuation = Mutex<CheckedContinuation<Void, Never>?>(nil)
    private let entered = Mutex(false)
    var hasEntered: Bool { entered.withLock { $0 } }
    func wait() async {
      await withCheckedContinuation { c in
        continuation.withLock { $0 = c }
        entered.withLock { $0 = true }
      }
    }
    func open() {
      continuation.withLock {
        $0?.resume()
        $0 = nil
      }
    }
  }

  struct GatedStopSignals: KeyboardStandbySignals {
    let base: StandbySessionStore
    let gate: StopGate
    func issueCommand(_ action: StandbyCommand.Action, sessionID: SessionID, at now: Date)
      async throws -> StandbyCommand
    {
      if action == .stop { await gate.wait() }
      return try await base.issueCommand(action, sessionID: sessionID, at: now)
    }
    func saveHeartbeat(_ heartbeat: KeyboardHeartbeat) async throws {
      try await base.saveHeartbeat(heartbeat)
    }
    func loadHostState() async throws -> StandbyHostState? { try await base.loadHostState() }
  }

  private func host(
    _ phase: StandbyHostState.Phase, session: SessionID? = nil, keeps: Bool = true,
    detached: Bool = false, mode: StandbyInsertionMode = .automatic,
    captureStartedAt: Date? = nil, at date: Date
  ) -> StandbyHostState {
    StandbyHostState(
      phase: phase, sessionID: session, updatedAt: date, insertionMode: mode,
      keepsRecordingWhenKeyboardCloses: keeps, isDetached: detached,
      captureStartedAt: captureStartedAt)
  }

  private func make(
    inserter: CountingInserter = CountingInserter(), clock: Clock,
    signals: (any KeyboardStandbySignals)? = nil
  ) -> (KeyboardStandbyDictation, StandbySessionStore) {
    let store = StandbySessionStore(directory: directory.url)
    let dictation = KeyboardStandbyDictation(
      signals: signals ?? store, inserter: inserter, now: { clock.now })
    return (dictation, store)
  }

  /// 待機中の本体アプリで録音を始め、本体アプリが録音中と知らせたところまで進める
  private func record(
    _ dictation: KeyboardStandbyDictation, _ store: StandbySessionStore, _ clock: Clock,
    keeps: Bool = true
  ) async throws -> SessionID {
    try await store.saveHostState(host(.standby, keeps: keeps, at: clock.now))
    await dictation.tick()
    await dictation.toggle()
    guard case .starting(let id) = dictation.state else {
      Issue.record("開始の待ちになっていない: \(dictation.state)")
      return SessionID()
    }
    try await store.saveHostState(host(.recording, session: id, keeps: keeps, at: clock.now))
    await dictation.tick()
    #expect(dictation.state == .recording(id))
    return id
  }

  @Test("#267: 続ける設定で録音中に閉じたら、取り消しを書かない")
  func closingDoesNotCancelWhenKept() async throws {
    let clock = Clock(base)
    let (dictation, store) = make(clock: clock)
    let id = try await record(dictation, store, clock)
    let before = try await store.loadCommand()

    await dictation.keyboardClosed(reason: .dismissed)

    #expect(dictation.state == .unavailable)
    #expect(try await store.loadCommand() == before)
    #expect(before?.action == .start && before?.sessionID == id)
  }

  @Test("iOS-06: 続けない設定では、今どおり閉じたら取り消す")
  func closingCancelsWhenNotKept() async throws {
    let clock = Clock(base)
    let (dictation, store) = make(clock: clock)
    let id = try await record(dictation, store, clock, keeps: false)

    await dictation.keyboardClosed(reason: .dismissed)

    let command = try await store.loadCommand()
    #expect(command?.action == .cancel)
    #expect(command?.sessionID == id)
  }

  @Test("iOS-09: 続ける設定でも、制限のある入力欄に移ったら取り消す")
  func restrictedFieldCancels() async throws {
    let clock = Clock(base)
    let (dictation, store) = make(clock: clock)
    let id = try await record(dictation, store, clock)

    await dictation.keyboardClosed(reason: .restricted)

    let command = try await store.loadCommand()
    #expect(command?.action == .cancel)
    #expect(command?.sessionID == id)
  }

  @Test("iOS-06: 続ける設定でも、開始の待ちのうちに閉じたら取り消す")
  func closingWhileStartingCancels() async throws {
    let clock = Clock(base)
    let (dictation, store) = make(clock: clock)
    try await store.saveHostState(host(.standby, at: clock.now))
    await dictation.tick()
    await dictation.toggle()
    guard case .starting(let id) = dictation.state else {
      Issue.record("開始の待ちになっていない")
      return
    }

    await dictation.keyboardClosed(reason: .dismissed)

    let command = try await store.loadCommand()
    #expect(command?.action == .cancel)
    #expect(command?.sessionID == id)
  }

  @Test("#267: 停止を書いている途中に閉じても、停止を上書きしない")
  func closingWhileStoppingKeepsStop() async throws {
    let clock = Clock(base)
    let gate = StopGate()
    let store = StandbySessionStore(directory: directory.url)
    let dictation = KeyboardStandbyDictation(
      signals: GatedStopSignals(base: store, gate: gate), inserter: CountingInserter(),
      now: { clock.now })
    let id = try await record(dictation, store, clock)

    let stopping = Task { await dictation.toggle() }
    while !gate.hasEntered { await Task.yield() }
    await dictation.keyboardClosed(reason: .dismissed)
    gate.open()
    await stopping.value

    let command = try await store.loadCommand()
    #expect(command?.action == .stop)
    #expect(command?.sessionID == id)
  }

  @Test("#267: 再表示したとき、本体アプリが録音中なら引き継ぎ、印を書き、本体アプリの開始時刻を返す")
  func resumesRecordingOnReappear() async throws {
    let clock = Clock(base)
    let (dictation, store) = make(clock: clock)
    let id = SessionID()
    let startedAt = clock.now
    clock.advance(30)
    try await store.saveHostState(
      host(.recording, session: id, detached: true, captureStartedAt: startedAt, at: clock.now))

    await dictation.tick()

    #expect(dictation.state == .recording(id))
    #expect(dictation.isResumedRecording)
    #expect(dictation.resumedCaptureStartedAt == startedAt)
    let heartbeat = try await store.loadHeartbeat()
    #expect(heartbeat?.sessionID == id)
    #expect(heartbeat?.at == clock.now)
  }

  @Test("#267: 続けない設定・途絶えた状態・取り消したセッションは引き継がない")
  func doesNotResumeOtherwise() async throws {
    let clock = Clock(base)
    let (dictation, store) = make(clock: clock)

    try await store.saveHostState(
      host(.recording, session: SessionID(), keeps: false, at: clock.now))
    await dictation.tick()
    #expect(dictation.state == .unavailable)

    try await store.saveHostState(host(.recording, session: SessionID(), at: clock.now))
    clock.advance(StandbyHostState.heartbeatTimeout.timeInterval + 1)
    await dictation.tick()
    #expect(dictation.state == .unavailable)

    // 自分で取り消した録音は、本体アプリの状態がまだ録音中でも引き継がない
    let id = try await record(dictation, store, clock)
    await dictation.cancel()
    #expect(dictation.state == .ready)
    try await store.saveHostState(host(.recording, session: id, at: clock.now))
    await dictation.tick()
    #expect(dictation.state == .unavailable)
  }

  @Test("#267: 引き継いだ録音の結果は、設定が自動挿入でも自動で入れない")
  func resumedResultIsNotInsertedAutomatically() async throws {
    let clock = Clock(base)
    let inserter = CountingInserter()
    let (dictation, store) = make(inserter: inserter, clock: clock)
    let id = SessionID()
    try await store.saveHostState(host(.recording, session: id, detached: true, at: clock.now))
    await dictation.tick()
    #expect(dictation.state == .recording(id))

    await dictation.toggle()
    #expect(dictation.state == .processing(id))
    #expect(try await store.loadCommand()?.action == .stop)

    try await store.saveHostState(host(.done, session: id, mode: .automatic, at: clock.now))
    await dictation.tick()

    #expect(dictation.state == .resultReady(id))
    #expect(inserter.insertedSessions.isEmpty)
  }

  @Test("#267: 引き継いだ後にまた閉じても、取り消さずに続ける")
  func resumedThenClosedAgainKeepsRecording() async throws {
    let clock = Clock(base)
    let (dictation, store) = make(clock: clock)
    let id = SessionID()
    try await store.saveHostState(host(.recording, session: id, detached: true, at: clock.now))
    await dictation.tick()
    #expect(dictation.state == .recording(id))

    await dictation.keyboardClosed(reason: .dismissed)

    #expect(try await store.loadCommand() == nil)
    clock.advance(1)
    try await store.saveHostState(host(.recording, session: id, detached: true, at: clock.now))
    await dictation.tick()
    #expect(dictation.state == .recording(id))
  }

  @Test("#267: 古い状態のファイル（新しい項目がない）は、続けない設定として読む。差し替えても新しい項目を保つ")
  func hostStateCompatibility() throws {
    let json = #"{"phase":"recording","updatedAt":0}"#
    let state = try JSONDecoder().decode(StandbyHostState.self, from: Data(json.utf8))
    #expect(state.keepsRecordingWhenKeyboardCloses == false)
    #expect(state.isDetached == false)
    #expect(state.captureStartedAt == nil)

    let full = host(
      .recording, session: SessionID(), detached: true, captureStartedAt: base, at: base)
    let replaced = full.with(insertionMode: .preview)
    #expect(replaced.insertionMode == .preview)
    #expect(replaced.keepsRecordingWhenKeyboardCloses)
    #expect(replaced.isDetached)
    #expect(replaced.captureStartedAt == base)
    let decoded = try JSONDecoder().decode(
      StandbyHostState.self, from: JSONEncoder().encode(replaced))
    #expect(decoded == replaced)
  }

  /// 生存の印の書き込みを、開くまで止める（開始の合図を書いている間の操作を試す）
  struct GatedHeartbeatSignals: KeyboardStandbySignals {
    let base: StandbySessionStore
    let gate: StopGate
    func issueCommand(_ action: StandbyCommand.Action, sessionID: SessionID, at now: Date)
      async throws -> StandbyCommand
    { try await base.issueCommand(action, sessionID: sessionID, at: now) }
    func saveHeartbeat(_ heartbeat: KeyboardHeartbeat) async throws {
      await gate.wait()
      try await base.saveHeartbeat(heartbeat)
    }
    func loadHostState() async throws -> StandbyHostState? { try await base.loadHostState() }
  }

  @Test("#267: 開始の合図を書いている間に取り消した録音も、本体アプリが録音中と知らせていても引き継がない")
  func cancelledWhileStartingIsNotResumed() async throws {
    let clock = Clock(base)
    let gate = StopGate()
    let store = StandbySessionStore(directory: directory.url)
    let dictation = KeyboardStandbyDictation(
      signals: GatedHeartbeatSignals(base: store, gate: gate), inserter: CountingInserter(),
      now: { clock.now })
    try await store.saveHostState(host(.standby, at: clock.now))
    await dictation.tick()

    let starting = Task { await dictation.toggle() }
    while !gate.hasEntered { await Task.yield() }
    await dictation.cancel()
    gate.open()
    await starting.value
    #expect(dictation.state == .ready)
    let cancelled = try await store.loadCommand()
    #expect(cancelled?.action == .cancel)
    let id = try #require(cancelled?.sessionID)

    // 本体アプリはまだ取り消しを読んでおらず、録音中と知らせている
    try await store.saveHostState(host(.recording, session: id, at: clock.now))
    await dictation.tick()
    #expect(dictation.state == .unavailable)
  }

  @Test("#267: 同じキーボードで閉じてすぐ戻り（本体アプリはまだ離れたと判定していない）、止めても自動では入れない")
  func sameInstanceReopenDoesNotAutoInsert() async throws {
    let clock = Clock(base)
    let inserter = CountingInserter()
    let (dictation, store) = make(inserter: inserter, clock: clock)
    let id = try await record(dictation, store, clock)

    await dictation.keyboardClosed(reason: .dismissed)
    clock.advance(1)
    try await store.saveHostState(host(.recording, session: id, at: clock.now))
    await dictation.tick()
    #expect(dictation.state == .recording(id))
    // 自分で始めた録音なので「閉じる前からの録音」とは案内しない
    #expect(dictation.isResumedRecording == false)

    await dictation.toggle()
    try await store.saveHostState(host(.done, session: id, mode: .automatic, at: clock.now))
    await dictation.tick()

    #expect(dictation.state == .resultReady(id))
    #expect(inserter.insertedSessions.isEmpty)
  }

  @Test("#267: 引き継いだ録音の開始時刻は、次に自分で始めた録音には使わない")
  func resumedStartTimeDoesNotLeak() async throws {
    let clock = Clock(base)
    let (dictation, store) = make(clock: clock)
    let resumed = SessionID()
    try await store.saveHostState(
      host(.recording, session: resumed, detached: true, captureStartedAt: base, at: clock.now))
    await dictation.tick()
    #expect(dictation.resumedCaptureStartedAt == base)

    await dictation.toggle()
    try await store.saveHostState(host(.done, session: resumed, at: clock.now))
    await dictation.tick()
    dictation.resultHandled()
    #expect(dictation.state == .ready)

    clock.advance(30)
    await dictation.toggle()
    guard case .starting(let next) = dictation.state else {
      Issue.record("開始の待ちになっていない: \(dictation.state)")
      return
    }
    try await store.saveHostState(host(.recording, session: next, at: clock.now))
    await dictation.tick()
    #expect(dictation.state == .recording(next))
    #expect(dictation.resumedCaptureStartedAt == nil)
  }

  @Test("#267: 閉じている間に離れた録音が捨てられたら、戻ったときに一度だけ理由を出す")
  func reportsDetachedFailureOnce() async throws {
    let clock = Clock(base)
    let (dictation, store) = make(clock: clock)
    let id = SessionID()
    let failed = StandbyHostState(
      phase: .failed, sessionID: id, updatedAt: clock.now, failure: .captureLimitExceeded,
      keepsRecordingWhenKeyboardCloses: true, isDetached: true)
    try await store.saveHostState(failed)

    await dictation.tick()
    #expect(dictation.state == .failed(.host(.captureLimitExceeded)))

    await dictation.keyboardClosed(reason: .dismissed)
    await dictation.tick()
    #expect(dictation.state == .ready)
  }
}
