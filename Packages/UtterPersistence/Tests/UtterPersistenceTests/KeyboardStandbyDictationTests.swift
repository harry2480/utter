import Foundation
import Synchronization
import Testing
import UtterCore

@testable import UtterPersistence

@MainActor
struct KeyboardStandbyDictationTests {
  private let directory = TemporaryDirectory()
  private let base = Date(timeIntervalSince1970: 1_800_000_000)

  /// 時刻を進められる時計
  final class Clock: Sendable {
    private let value: Mutex<Date>
    init(_ start: Date) { value = Mutex(start) }
    var now: Date { value.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { value.withLock { $0 = $0.addingTimeInterval(seconds) } }
  }

  /// 挿入の回数を数え、決めた結果を返す
  final class CountingInserter: KeyboardStandbyInserting {
    private let calls = Mutex<[SessionID]>([])
    private let outcome: SharedResultInsertionOutcome
    init(outcome: SharedResultInsertionOutcome = .inserted) { self.outcome = outcome }
    var insertedSessions: [SessionID] { calls.withLock { $0 } }
    func insertResult(
      sessionID: SessionID, isStillTarget: @escaping SharedResultInsertionTargetCheck
    ) async throws -> SharedResultInsertionOutcome {
      calls.withLock { $0.append(sessionID) }
      return outcome
    }
  }

  /// 生存の印の書き込みを、開くまで止める合図（開始の合図を書いている間の操作を試す）
  final class HeartbeatGate: Sendable {
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

  struct GatedSignals: KeyboardStandbySignals {
    let base: StandbySessionStore
    let gate: HeartbeatGate
    func issueCommand(_ action: StandbyCommand.Action, sessionID: SessionID, at now: Date)
      async throws -> StandbyCommand
    { try await base.issueCommand(action, sessionID: sessionID, at: now) }
    func saveHeartbeat(_ heartbeat: KeyboardHeartbeat) async throws {
      await gate.wait()
      try await base.saveHeartbeat(heartbeat)
    }
    func loadHostState() async throws -> StandbyHostState? { try await base.loadHostState() }
  }

  private func make(
    inserter: CountingInserter = CountingInserter(), clock: Clock
  ) -> (KeyboardStandbyDictation, StandbySessionStore) {
    let store = StandbySessionStore(directory: directory.url)
    let dictation = KeyboardStandbyDictation(
      signals: store, inserter: inserter, now: { clock.now })
    return (dictation, store)
  }

  private func host(
    _ phase: StandbyHostState.Phase, session: SessionID? = nil,
    mode: StandbyInsertionMode = .automatic,
    failure: StandbyFailure? = nil, at date: Date
  ) -> StandbyHostState {
    StandbyHostState(
      phase: phase, sessionID: session, updatedAt: date, failure: failure, insertionMode: mode)
  }

  /// 待機中の本体アプリを用意して、マイクの操作で録音を始めたところまで進める
  private func startRecording(
    _ dictation: KeyboardStandbyDictation, _ store: StandbySessionStore, _ clock: Clock
  ) async throws -> SessionID {
    try await store.saveHostState(host(.standby, at: clock.now))
    await dictation.tick()
    #expect(dictation.state == .ready)
    await dictation.toggle()
    guard case .starting(let id) = dictation.state else {
      Issue.record("開始の待ちになっていない: \(dictation.state)")
      return SessionID()
    }
    return id
  }

  /// 録音が始まった（本体アプリが録音中と知らせた）ところまで進める
  private func startAndRecord(
    _ dictation: KeyboardStandbyDictation, _ store: StandbySessionStore, _ clock: Clock
  ) async throws -> SessionID {
    let id = try await startRecording(dictation, store, clock)
    try await store.saveHostState(host(.recording, session: id, at: clock.now))
    await dictation.tick()
    #expect(dictation.state == .recording(id))
    return id
  }

  @Test("iOS-03: 待機中でなければ使えない。待機していれば録音を始められる")
  func availabilityFollowsHost() async throws {
    let clock = Clock(base)
    let (dictation, store) = make(clock: clock)
    await dictation.tick()
    #expect(dictation.state == .unavailable)

    try await store.saveHostState(host(.standby, at: clock.now))
    await dictation.tick()
    #expect(dictation.state == .ready)

    // 本体アプリの更新が途絶えたら、待機していないものとして扱う
    clock.advance(StandbyHostState.heartbeatTimeout.timeInterval + 1)
    await dictation.tick()
    #expect(dictation.state == .unavailable)
  }

  @Test("iOS-03: マイクの操作で開始の合図、もう一度で停止の合図を書く")
  func toggleIssuesStartAndStop() async throws {
    let clock = Clock(base)
    let (dictation, store) = make(clock: clock)
    let id = try await startRecording(dictation, store, clock)
    #expect(try await store.loadCommand()?.action == .start)
    #expect(try await store.loadCommand()?.sessionID == id)

    try await store.saveHostState(host(.recording, session: id, at: clock.now))
    await dictation.tick()
    #expect(dictation.state == .recording(id))

    await dictation.toggle()
    #expect(dictation.state == .processing(id))
    #expect(try await store.loadCommand()?.action == .stop)
  }

  @Test("iOS-06: 録音中は間隔を空けて生存の印を書く")
  func writesHeartbeatWhileRecording() async throws {
    let clock = Clock(base)
    let (dictation, store) = make(clock: clock)
    let id = try await startRecording(dictation, store, clock)
    try await store.saveHostState(host(.recording, session: id, at: clock.now))
    #expect(try await store.loadHeartbeat()?.at == base)

    // 間隔より短い間は書き直さない
    clock.advance(0.3)
    try await store.saveHostState(host(.recording, session: id, at: clock.now))
    await dictation.tick()
    #expect(try await store.loadHeartbeat()?.at == base)

    clock.advance(1)
    try await store.saveHostState(host(.recording, session: id, at: clock.now))
    await dictation.tick()
    #expect(try await store.loadHeartbeat()?.at == clock.now)
    #expect(try await store.loadHeartbeat()?.sessionID == id)
  }

  @Test("iOS-05・iAC-04: 既定は停止後に自動で挿入し、読み直しを重ねても1回だけ")
  func autoInsertsOnce() async throws {
    let clock = Clock(base)
    let inserter = CountingInserter()
    let (dictation, store) = make(inserter: inserter, clock: clock)
    let id = try await startRecording(dictation, store, clock)
    try await store.saveHostState(host(.recording, session: id, at: clock.now))
    await dictation.tick()
    await dictation.toggle()

    try await store.saveHostState(host(.done, session: id, at: clock.now))
    await dictation.tick()
    #expect(dictation.state == .inserted)
    await dictation.tick()
    await dictation.tick()
    #expect(inserter.insertedSessions == [id])
  }

  @Test("iOS-05: プレビューの設定では自動で挿入せず、結果ができたことを知らせる")
  func previewModeDoesNotInsert() async throws {
    let clock = Clock(base)
    let inserter = CountingInserter()
    let (dictation, store) = make(inserter: inserter, clock: clock)
    let id = try await startAndRecord(dictation, store, clock)
    await dictation.toggle()

    try await store.saveHostState(host(.done, session: id, mode: .preview, at: clock.now))
    await dictation.tick()
    #expect(dictation.state == .resultReady(id))
    #expect(inserter.insertedSessions.isEmpty)
  }

  @Test("iOS-IPC-03: 挿入を確認できなければ、自動ではやり直さない")
  func unknownInsertionIsNotRetried() async throws {
    let clock = Clock(base)
    let inserter = CountingInserter(outcome: .insertionUnknown)
    let (dictation, store) = make(inserter: inserter, clock: clock)
    let id = try await startAndRecord(dictation, store, clock)
    await dictation.toggle()

    try await store.saveHostState(host(.done, session: id, at: clock.now))
    await dictation.tick()
    await dictation.tick()
    #expect(dictation.state == .insertionUnknown(id))
    #expect(inserter.insertedSessions == [id])
  }

  @Test("iOS-06: 録音中にキーボードが閉じられたら取り消しの合図を書く")
  func closingCancelsRecording() async throws {
    let clock = Clock(base)
    let (dictation, store) = make(clock: clock)
    let id = try await startRecording(dictation, store, clock)
    try await store.saveHostState(host(.recording, session: id, at: clock.now))
    await dictation.tick()

    await dictation.keyboardClosed()

    #expect(try await store.loadCommand()?.action == .cancel)
    #expect(try await store.loadCommand()?.sessionID == id)
    #expect(dictation.state == .unavailable)
  }

  @Test("iOS-06: 停止後、挿入までにキーボードが閉じられたら自動挿入しない")
  func closingBeforeInsertionSkipsAutoInsert() async throws {
    let clock = Clock(base)
    let inserter = CountingInserter()
    let (dictation, store) = make(inserter: inserter, clock: clock)
    let id = try await startAndRecord(dictation, store, clock)
    await dictation.toggle()
    #expect(dictation.state == .processing(id))

    await dictation.keyboardClosed()
    // 閉じた後に結果ができても挿入しない（次に表示したときの挿入候補になる）
    try await store.saveHostState(host(.done, session: id, at: clock.now))
    await dictation.tick()

    #expect(inserter.insertedSessions.isEmpty)
    #expect(try await store.loadCommand()?.action == .stop)  // 処理中は取り消しを書かない
    #expect(dictation.state == .ready)  // 待機中の本体アプリの状態から、次の操作に戻る
  }

  @Test("iOS-06: 本体アプリが録音を捨てたら、その理由で失敗にする")
  func hostFailureIsReported() async throws {
    let clock = Clock(base)
    let (dictation, store) = make(clock: clock)
    let id = try await startRecording(dictation, store, clock)
    try await store.saveHostState(
      host(.failed, session: id, failure: .captureLimitExceeded, at: clock.now))
    await dictation.tick()
    #expect(dictation.state == .failed(.host(.captureLimitExceeded)))
  }

  @Test("開始の合図に本体アプリが応えなければ、取り消しを書いて失敗にする")
  func startTimesOut() async throws {
    let clock = Clock(base)
    let (dictation, store) = make(clock: clock)
    let id = try await startRecording(dictation, store, clock)

    clock.advance(3)
    try await store.saveHostState(host(.standby, at: clock.now))
    await dictation.tick()
    #expect(dictation.state == .starting(id))

    clock.advance(6)
    try await store.saveHostState(host(.standby, at: clock.now))
    await dictation.tick()
    #expect(dictation.state == .failed(.startTimedOut))
    #expect(try await store.loadCommand()?.action == .cancel)
  }

  @Test("録音中に本体アプリの状態が途絶えたら失敗にする")
  func hostLostWhileRecording() async throws {
    let clock = Clock(base)
    let (dictation, store) = make(clock: clock)
    let id = try await startRecording(dictation, store, clock)
    try await store.saveHostState(host(.recording, session: id, at: clock.now))
    await dictation.tick()

    clock.advance(StandbyHostState.heartbeatTimeout.timeInterval + 1)
    await dictation.tick()
    #expect(dictation.state == .failed(.hostLost))
  }

  @Test("失敗や挿入の後でも、待機中ならもう一度録音を始められる")
  func canStartAgainAfterResult() async throws {
    let clock = Clock(base)
    let (dictation, store) = make(clock: clock)
    let first = try await startAndRecord(dictation, store, clock)
    await dictation.toggle()
    try await store.saveHostState(host(.done, session: first, at: clock.now))
    await dictation.tick()
    #expect(dictation.state == .inserted)

    await dictation.toggle()
    guard case .starting(let second) = dictation.state else {
      Issue.record("開始の待ちになっていない: \(dictation.state)")
      return
    }
    #expect(second != first)
  }

  @Test("開始の待ちの間にもう一度押したら、停止ではなく取り消しを書いて戻る（開始が上書きされて処理中に固まらない）")
  func stopWhileStartingCancels() async throws {
    let clock = Clock(base)
    let (dictation, store) = make(clock: clock)
    let id = try await startRecording(dictation, store, clock)

    await dictation.toggle()

    #expect(try await store.loadCommand()?.action == .cancel)
    #expect(try await store.loadCommand()?.sessionID == id)
    #expect(dictation.state == .ready)
  }

  @Test("録音中の「やめる」は、取り消しを書いて待機に戻る（入れない）")
  func cancelWhileRecordingWritesCancel() async throws {
    let clock = Clock(base)
    let (dictation, store) = make(clock: clock)
    let id = try await startRecording(dictation, store, clock)
    try await store.saveHostState(host(.recording, session: id, at: clock.now))
    await dictation.tick()
    #expect(dictation.state == .recording(id))

    await dictation.cancel()

    #expect(try await store.loadCommand()?.action == .cancel)
    #expect(try await store.loadCommand()?.sessionID == id)
    #expect(dictation.state == .ready)
  }

  @Test("開始の合図を書いている間の「やめる」は、無視せず、開始が済んでから取り消しを書く")
  func cancelDuringStartIssuingIsDeferred() async throws {
    let clock = Clock(base)
    let store = StandbySessionStore(directory: directory.url)
    let gate = HeartbeatGate()
    let dictation = KeyboardStandbyDictation(
      signals: GatedSignals(base: store, gate: gate), inserter: CountingInserter(),
      now: { clock.now })
    try await store.saveHostState(host(.standby, at: clock.now))
    await dictation.tick()
    #expect(dictation.state == .ready)

    let toggling = Task { await dictation.toggle() }
    // 書き込みに失敗するなどでゲートに届かない場合は、待ち続けずに失敗にする
    var spins = 0
    while !gate.hasEntered && spins < 100_000 {
      await Task.yield()
      spins += 1
    }
    #expect(gate.hasEntered, "生存の印の書き込みに届かなかった")
    guard gate.hasEntered else {
      toggling.cancel()
      return
    }
    await dictation.cancel()
    gate.open()
    await toggling.value

    #expect(try await store.loadCommand()?.action == .cancel)
    #expect(dictation.state == .ready)
  }

  @Test("開始の合図を書いている間に録音中へ進んでも、保留した取り消しは送られる")
  func cancelDuringStartIssuingAfterRecordingBegan() async throws {
    let clock = Clock(base)
    let store = StandbySessionStore(directory: directory.url)
    let gate = HeartbeatGate()
    let dictation = KeyboardStandbyDictation(
      signals: GatedSignals(base: store, gate: gate), inserter: CountingInserter(),
      now: { clock.now })
    try await store.saveHostState(host(.standby, at: clock.now))
    await dictation.tick()

    let toggling = Task { await dictation.toggle() }
    var spins = 0
    while !gate.hasEntered && spins < 100_000 {
      await Task.yield()
      spins += 1
    }
    guard gate.hasEntered, let command = try await store.loadCommand() else {
      Issue.record("開始の合図に届かなかった")
      toggling.cancel()
      return
    }
    await dictation.cancel()
    try await store.saveHostState(host(.recording, session: command.sessionID, at: clock.now))
    await dictation.tick()
    #expect(dictation.state == .recording(command.sessionID))
    gate.open()
    await toggling.value

    #expect(try await store.loadCommand()?.action == .cancel)
    #expect(dictation.state == .ready)
  }

  @Test("待機中・処理中の「やめる」は何も書かない")
  func cancelOutsideRecordingDoesNothing() async throws {
    let clock = Clock(base)
    let (dictation, store) = make(clock: clock)
    await dictation.cancel()
    #expect(try await store.loadCommand() == nil)
    #expect(dictation.state == .unavailable)
  }

  @Test("停止のあと、本体アプリが結果を返さなければ待ち続けずに失敗にする")
  func processingTimesOut() async throws {
    let clock = Clock(base)
    let (dictation, store) = make(clock: clock)
    let id = try await startRecording(dictation, store, clock)
    try await store.saveHostState(host(.recording, session: id, at: clock.now))
    await dictation.tick()
    await dictation.toggle()

    clock.advance(60)
    try await store.saveHostState(host(.standby, at: clock.now))
    await dictation.tick()
    #expect(dictation.state == .processing(id))

    clock.advance(40)
    try await store.saveHostState(host(.standby, at: clock.now))
    await dictation.tick()
    #expect(dictation.state == .failed(.hostLost))
  }

  @Test("挿入や失敗のあとで本体アプリが待機を終えたら、本体アプリを開く案内に戻る")
  func returnsToUnavailableWhenHostEnds() async throws {
    let clock = Clock(base)
    let (dictation, store) = make(clock: clock)
    let id = try await startAndRecord(dictation, store, clock)
    await dictation.toggle()
    try await store.saveHostState(host(.done, session: id, at: clock.now))
    await dictation.tick()
    #expect(dictation.state == .inserted)

    try await store.saveHostState(host(.off, at: clock.now))
    await dictation.tick()
    #expect(dictation.state == .unavailable)
  }

  @Test("iOS-06: キーボードが表示されていなければ自動挿入せず、結果を候補として残す")
  func doesNotInsertWhenNotVisible() async throws {
    let clock = Clock(base)
    let inserter = CountingInserter()
    let store = StandbySessionStore(directory: directory.url)
    let dictation = KeyboardStandbyDictation(
      signals: store, inserter: inserter, canInsert: { false }, now: { clock.now })
    let id = try await startAndRecord(dictation, store, clock)
    await dictation.toggle()

    try await store.saveHostState(host(.done, session: id, at: clock.now))
    await dictation.tick()

    #expect(inserter.insertedSessions.isEmpty)
    #expect(dictation.state != .inserted)
  }

  @Test("プレビューで挿入し終えたら、結果の案内を消して次の録音に進める")
  func resultHandledReturnsToReady() async throws {
    let clock = Clock(base)
    let (dictation, store) = make(clock: clock)
    let id = try await startAndRecord(dictation, store, clock)
    await dictation.toggle()
    try await store.saveHostState(host(.done, session: id, mode: .preview, at: clock.now))
    await dictation.tick()
    #expect(dictation.state == .resultReady(id))

    dictation.resultHandled()
    #expect(dictation.state == .ready)
  }

  /// 開くまで止める。先に開いたときも開いたままにし、後から待ち始めた Task を止めない
  final class LatchedGate: Sendable {
    private struct State {
      var isOpen = false
      var hasEntered = false
      var continuation: CheckedContinuation<Void, Never>?
    }
    private let state = Mutex(State())
    var hasEntered: Bool { state.withLock { $0.hasEntered } }
    func wait() async {
      await withCheckedContinuation { c in
        let resumeNow = state.withLock {
          $0.hasEntered = true
          if $0.isOpen { return true }
          $0.continuation = c
          return false
        }
        if resumeNow { c.resume() }
      }
    }
    func open() {
      let waiting = state.withLock {
        $0.isOpen = true
        defer { $0.continuation = nil }
        return $0.continuation
      }
      waiting?.resume()
    }
  }

  /// 挿入の確保を、開くまで止める。開いた後、入れる直前の判定の値を記録する（#271）
  final class GatedInserter: KeyboardStandbyInserting {
    let gate = LatchedGate()
    private let checks = Mutex<[Bool]>([])
    var recordedChecks: [Bool] { checks.withLock { $0 } }
    func insertResult(
      sessionID: SessionID, isStillTarget: @escaping SharedResultInsertionTargetCheck
    ) async throws -> SharedResultInsertionOutcome {
      await gate.wait()
      let stillTarget = await isStillTarget()
      checks.withLock { $0.append(stillTarget) }
      return stillTarget ? .inserted : .insertionUnknown
    }
  }

  /// 自動挿入の確保を待っているところまで進め、`whileWaiting` を行ってから確保を終える
  private func autoInsert(
    whileWaiting: (KeyboardStandbyDictation) async -> Void
  ) async throws -> (KeyboardStandbyDictation, GatedInserter) {
    let clock = Clock(base)
    let store = StandbySessionStore(directory: directory.url)
    let inserter = GatedInserter()
    let dictation = KeyboardStandbyDictation(
      signals: store, inserter: inserter, now: { clock.now })
    try await store.saveHostState(host(.standby, at: clock.now))
    await dictation.tick()
    await dictation.toggle()
    guard case .starting(let id) = dictation.state else {
      Issue.record("開始の待ちになっていない: \(dictation.state)")
      return (dictation, inserter)
    }
    try await store.saveHostState(host(.recording, session: id, at: clock.now))
    await dictation.tick()
    await dictation.toggle()
    try await store.saveHostState(host(.done, session: id, at: clock.now))

    let ticking = Task { await dictation.tick() }
    var spins = 0
    while !inserter.gate.hasEntered && spins < 100_000 {
      await Task.yield()
      spins += 1
    }
    #expect(inserter.gate.hasEntered, "挿入に届かなかった")
    guard inserter.gate.hasEntered else {
      // 待つ間の操作は行わずに終える。開いたままのゲートなので、遅れて挿入に届いても止まらない
      inserter.gate.open()
      await ticking.value
      return (dictation, inserter)
    }
    await whileWaiting(dictation)
    inserter.gate.open()
    await ticking.value
    return (dictation, inserter)
  }

  @Test("iOS-06・#271: 自動挿入の確保を待つ間に閉じたら、表示し直しても入れる直前の判定で挿入しない")
  func closingDuringAutoInsertBlocksInsertion() async throws {
    let (dictation, inserter) = try await autoInsert { dictation in
      // 閉じた瞬間に待たずに記録したところで、取り消しなど（`keyboardClosed`）より先に確保が済む
      dictation.invalidatePendingInsertion()
    }
    #expect(inserter.recordedChecks == [false])
    #expect(dictation.state != .inserted)
  }

  @Test("iOS-05・#271: 閉じずに確保を待ち終えたら、今までどおり挿入する")
  func autoInsertWithoutClosingInserts() async throws {
    let (dictation, inserter) = try await autoInsert { _ in }
    #expect(inserter.recordedChecks == [true])
    #expect(dictation.state == .inserted)
  }
}
