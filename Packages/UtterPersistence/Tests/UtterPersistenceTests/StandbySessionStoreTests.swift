import Foundation
import Testing
import UtterCore

@testable import UtterPersistence

struct StandbySessionStoreTests {
  private let directory = TemporaryDirectory()
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  @Test("iOS-04: キーボードが書いた合図を本体アプリが読める。書いていなければ nil")
  func issueAndLoadCommand() async throws {
    let store = StandbySessionStore(directory: directory.url)
    #expect(try await store.loadCommand() == nil)
    let session = SessionID()

    let command = try await store.issueCommand(.start, sessionID: session, at: now)

    let loaded = try await StandbySessionStore(directory: directory.url).loadCommand()
    #expect(loaded == command)
    #expect(loaded?.action == .start)
    #expect(loaded?.sessionID == session)
  }

  @Test("iOS-04: 合図の番号は、同じ時刻や時計が戻ったときも前の番号より必ず大きい（重複の排除に使う）")
  func sequenceIncreases() async throws {
    let store = StandbySessionStore(directory: directory.url)
    let session = SessionID()
    let first = try await store.issueCommand(.start, sessionID: session, at: now)
    let sameTime = try await store.issueCommand(.stop, sessionID: session, at: now)
    let earlier = try await store.issueCommand(
      .start, sessionID: SessionID(), at: now.addingTimeInterval(-60))

    #expect(first.sequence < sameTime.sequence)
    #expect(sameTime.sequence < earlier.sequence)
  }

  @Test("iOS-04: 前の合図が壊れていても、新しい合図を書ける")
  func issueOverCorruptedCommand() async throws {
    let store = StandbySessionStore(directory: directory.url)
    try await store.issueCommand(.start, sessionID: SessionID(), at: now)
    try Data("{".utf8).write(to: directory.url.appendingPathComponent("command.json"))

    await #expect(throws: SharedResultStoreError.corruptedResult) {
      try await store.loadCommand()
    }
    let command = try await store.issueCommand(.cancel, sessionID: SessionID(), at: now)
    #expect(try await store.loadCommand() == command)
  }

  @Test("iOS-04, iOS-06: 本体アプリの状態とキーボードの生存の印を、それぞれ書き換えて読める")
  func hostStateAndHeartbeat() async throws {
    let store = StandbySessionStore(directory: directory.url)
    #expect(try await store.loadHostState() == nil)
    #expect(try await store.loadHeartbeat() == nil)
    let session = SessionID()

    try await store.saveHostState(
      StandbyHostState(phase: .recording, sessionID: session, updatedAt: now))
    let failed = StandbyHostState(
      phase: .failed, sessionID: session, updatedAt: now.addingTimeInterval(1),
      failure: .keyboardHeartbeatLost)
    try await store.saveHostState(failed)
    let heartbeat = KeyboardHeartbeat(sessionID: session, at: now)
    try await store.saveHeartbeat(heartbeat)

    #expect(try await store.loadHostState() == failed)
    #expect(try await store.loadHeartbeat() == heartbeat)
  }

  @Test("iOS-04: 待機していない・更新が途絶えた本体アプリは、待機中とみなさない")
  func hostStateAliveness() {
    let standby = StandbyHostState(phase: .standby, sessionID: nil, updatedAt: now)
    #expect(standby.isAlive(at: now.addingTimeInterval(8)))
    #expect(!standby.isAlive(at: now.addingTimeInterval(8.5)))
    #expect(!StandbyHostState(phase: .off, sessionID: nil, updatedAt: now).isAlive(at: now))
  }

  @Test("iOS-IPC-04: 状態のファイルに、本文や音声を置く欄がない（理由は決まった値だけ）")
  func noFreeText() async throws {
    let store = StandbySessionStore(directory: directory.url)
    try await store.saveHostState(
      StandbyHostState(
        phase: .failed, sessionID: SessionID(), updatedAt: now, failure: .processingFailed))
    let data = try Data(contentsOf: directory.url.appendingPathComponent("host.json"))
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(Set(object.keys) == ["phase", "sessionID", "updatedAt", "failure", "insertionMode"])
  }

  @Test("挿入のしかたを持たない古い状態のファイルは、自動挿入として読める")
  func legacyHostStateDefaultsToAutomatic() throws {
    let json = #"{"phase":"standby","updatedAt":0}"#
    let state = try JSONDecoder().decode(StandbyHostState.self, from: Data(json.utf8))
    #expect(state.insertionMode == .automatic)
  }
}
