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
    func insertResult(sessionID: SessionID) async throws -> SharedResultInsertionOutcome {
      calls.withLock { $0.append(sessionID) }
      return outcome
    }
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
}
