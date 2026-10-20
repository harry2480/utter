import Foundation
import GRDB
import Synchronization
import Testing
import UtterCore

@testable import UtterPersistence

struct InputHistoryStoreTests {
  private let store: InputHistoryStore
  private let createdAt = Date(timeIntervalSince1970: 1_800_000_000)

  private static let editor = "com.example.editor"
  private static let allowed = SensitiveInputPolicy().decide(
    SensitiveInputContext(secureField: .off, secureEventInput: .off, app: editor))
  private static let secureField = SensitiveInputPolicy().decide(
    SensitiveInputContext(secureField: .on, secureEventInput: .off, app: editor))

  init() throws {
    store = InputHistoryStore(database: try UtterDatabase.inMemory())
  }

  private func record(
    _ text: String, session: SessionID = SessionID(), after seconds: TimeInterval = 0,
    enabled: Bool = true, sensitivity: SensitiveInputDecision = allowed
  ) throws -> InputHistorySkipReason? {
    try store.record(
      text, session: session, at: createdAt.addingTimeInterval(seconds),
      historyEnabled: { enabled }, sensitivity: { sensitivity })
  }

  @Test("AC-12: 履歴が無効なら保存しない")
  func doesNotRecordWhenDisabled() throws {
    #expect(try record("明日の会議は10時からです。", enabled: false) == .disabled)
    #expect(try store.entries().isEmpty)
  }

  @Test(
    "AC-12: 機密入力・判定できない入力先では、履歴が有効でも保存しない",
    arguments: [
      SensitiveInputContext(secureField: .on, secureEventInput: .off, app: editor),
      SensitiveInputContext(secureField: .off, secureEventInput: .on, app: editor),
      SensitiveInputContext(secureField: .unknown, secureEventInput: .off, app: editor),
      SensitiveInputContext(secureField: .off, secureEventInput: .off, app: nil),
      SensitiveInputContext(secureField: .off, secureEventInput: .off, app: "com.example.vault"),
    ])
  func doesNotRecordSensitiveInput(_ context: SensitiveInputContext) throws {
    let decision = SensitiveInputPolicy(sensitiveApps: ["com.example.vault"]).decide(context)

    #expect(try record("password123", sensitivity: decision) == .sensitiveInput)
    #expect(try store.entries().isEmpty)
  }

  @Test("AC-12: 機密入力なら、履歴の設定を読まずに保存しない")
  func sensitiveInputSkipsWithoutReadingSetting() throws {
    let reason = try store.record(
      "秘密", session: SessionID(), at: createdAt,
      historyEnabled: {
        Issue.record("機密入力では設定を読まない")
        return true
      }, sensitivity: { Self.secureField })

    #expect(reason == .sensitiveInput)
  }

  @Test("AC-12: 入力先は書き込み待ちの後に判定し、待つ間に機密入力へ移ったら保存しない")
  func decidesSensitivityAfterWaitingForWrite() throws {
    let database = try UtterDatabase.inMemory()
    let history = InputHistoryStore(database: database)
    let decision = Mutex(Self.allowed)
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let done = DispatchSemaphore(value: 0)
    let reason = Mutex<InputHistorySkipReason?>(nil)
    let at = createdAt

    // 別の書き込みでキューを塞ぎ、その間に保存を始める
    DispatchQueue.global().async {
      try? database.writer.write { _ in
        entered.signal()
        release.wait()
      }
    }
    entered.wait()
    DispatchQueue.global().async {
      let result = try? history.record(
        "移った後の本文", session: SessionID(), at: at, historyEnabled: { true },
        sensitivity: { decision.withLock { $0 } })
      reason.withLock { $0 = result ?? nil }
      done.signal()
    }
    // 書き込みを待つ間に、入力先がパスワード欄へ移る
    decision.withLock { $0 = Self.secureField }
    release.signal()
    done.wait()

    #expect(reason.withLock { $0 } == .sensitiveInput)
    #expect(try history.entries().isEmpty)
  }

  @Test("AC-12: 設定は書き込みの中で読み、無効にした後の保存は削除の後に残らない")
  func readsSettingInsideWrite() throws {
    let enabled = Mutex(true)
    try record("無効にする前", after: 0)
    // 利用者が設定を無効にしてから全削除する
    enabled.withLock { $0 = false }
    try store.removeAll()

    let reason = try store.record(
      "無効にした後", session: SessionID(), at: createdAt,
      historyEnabled: { enabled.withLock { $0 } }, sensitivity: { Self.allowed })

    #expect(reason == .disabled)
    #expect(try store.entries().isEmpty)
  }

  @Test("7章: 空・空白だけの本文は保存しない", arguments: ["", " ", "\n\t"])
  func doesNotRecordEmptyText(_ text: String) throws {
    #expect(try record(text) == .emptyText)
    #expect(try store.entries().isEmpty)
  }

  @Test("7章: 有効で機密入力でなければ保存し、新しい順に返す")
  func recordsNewestFirst() throws {
    let first = SessionID()
    let second = SessionID()
    #expect(try record("一つ目", session: first, after: 0) == nil)
    #expect(try record("二つ目", session: second, after: 10) == nil)

    #expect(
      try store.entries() == [
        InputHistoryEntry(sessionID: second, text: "二つ目", createdAt: createdAt + 10),
        InputHistoryEntry(sessionID: first, text: "一つ目", createdAt: createdAt),
      ])
    #expect(try store.entries(limit: 1).map(\.sessionID) == [second])
    #expect(try store.entries(limit: 0).isEmpty)
  }

  @Test("7章: 同じセッションを保存し直すと置き換え、1セッション1件にする")
  func replacesSameSession() throws {
    let session = SessionID()
    try record("最初の結果", session: session, after: 0)
    try record("挿入し直した結果", session: session, after: 5)

    #expect(
      try store.entries() == [
        InputHistoryEntry(sessionID: session, text: "挿入し直した結果", createdAt: createdAt + 5)
      ])
  }

  @Test("7章: 作成時刻が同じなら、後から保存した（保存し直した）ものを先に返す")
  func ordersBySaveWhenTimesAreEqual() throws {
    let first = SessionID()
    let second = SessionID()
    try record("一つ目", session: first)
    try record("二つ目", session: second)
    try record("一つ目を保存し直した", session: first)

    #expect(try store.entries().map(\.sessionID) == [first, second])
    #expect(try store.entries(limit: -1).isEmpty)
  }

  @Test("7章: 削除した本文はデータベースのファイルに残らない")
  func deletedTextDoesNotRemainInFile() throws {
    let directory = TemporaryDirectory()
    try FileManager.default.createDirectory(at: directory.url, withIntermediateDirectories: true)
    let url = directory.url.appendingPathComponent("utter.sqlite")
    let marker = "削除後に残ってはいけない本文-0123456789"
    do {
      let history = InputHistoryStore(database: try UtterDatabase.open(at: url))
      try history.record(
        marker, session: SessionID(), at: createdAt, historyEnabled: { true },
        sensitivity: { Self.allowed })
      try history.removeAll()
    }

    let bytes = try Data(contentsOf: url)
    #expect(bytes.range(of: Data(marker.utf8)) == nil)
  }

  @Test("AC-12: セッションごと・すべての履歴を削除できる")
  func removesEntries() throws {
    let kept = SessionID()
    let removed = SessionID()
    try record("残す", session: kept)
    try record("消す", session: removed, after: 1)

    try store.remove(session: removed)
    try store.remove(session: SessionID())
    #expect(try store.entries().map(\.sessionID) == [kept])

    try store.removeAll()
    #expect(try store.entries().isEmpty)
  }

  @Test("7章: v1 のデータベースを開くと入力履歴の表を追加し、既存の辞書を保つ")
  func migratesFromV1() throws {
    let directory = TemporaryDirectory()
    try FileManager.default.createDirectory(at: directory.url, withIntermediateDirectories: true)
    let url = directory.url.appendingPathComponent("utter.sqlite")
    do {
      let queue = try DatabaseQueue(path: url.path)
      try UtterDatabase.migrator.migrate(queue, upTo: "v1")
      try queue.write { db in
        try db.execute(sql: "INSERT INTO dictionaryTerm (spelling) VALUES ('utter')")
      }
    }

    let database = try UtterDatabase.open(at: url)

    #expect(try DictionaryStore(database: database).terms() == ["utter"])
    let history = InputHistoryStore(database: database)
    try history.record(
      "移行後の履歴", session: SessionID(), at: createdAt, historyEnabled: { true },
      sensitivity: { Self.allowed })
    #expect(try history.entries().map(\.text) == ["移行後の履歴"])
  }

  @Test("REC-06: 文字列表現に本文を含めない")
  func redactsText() {
    let entry = InputHistoryEntry(sessionID: SessionID(), text: "秘密の発話", createdAt: createdAt)
    let outputs = [
      String(describing: entry), String(reflecting: entry),
      String(describing: Mirror(reflecting: entry).children.map(\.value)),
    ]

    for output in outputs {
      #expect(!output.contains("秘密の発話"))
    }
    #expect(String(describing: entry).contains("length: 5"))
  }
}
