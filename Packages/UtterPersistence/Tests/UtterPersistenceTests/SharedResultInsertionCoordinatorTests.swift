import Foundation
import Synchronization
import Testing
import UtterCore

@testable import UtterPersistence

struct SharedResultInsertionCoordinatorTests {
  private let directory = TemporaryDirectory()
  private let sessionID = SessionID()
  private let createdAt = Date(timeIntervalSince1970: 1_800_000_000)

  /// 挿入した本文を記録し、決めた確認結果を返す。挿入中に別の操作を割り込ませられる
  final class RecordingInserter: SharedResultTextInserter {
    private let inserted = Mutex<[String]>([])
    let confirmation: SharedResultInsertionConfirmation
    let duringInsertion: @Sendable () async throws -> Void

    init(
      confirmation: SharedResultInsertionConfirmation = .confirmed,
      duringInsertion: @escaping @Sendable () async throws -> Void = {}
    ) {
      self.confirmation = confirmation
      self.duringInsertion = duringInsertion
    }

    var insertedTexts: [String] { inserted.withLock { $0 } }

    func insert(_ text: String) async -> SharedResultInsertionConfirmation {
      inserted.withLock { $0.append(text) }
      do {
        try await duringInsertion()
      } catch {
        Issue.record(error, "挿入中の割り込みに失敗した")
      }
      return confirmation
    }
  }

  private func after(_ seconds: TimeInterval) -> Date {
    createdAt.addingTimeInterval(seconds)
  }

  private func coordinator(
    _ inserter: RecordingInserter, at seconds: TimeInterval = 1
  ) -> SharedResultInsertionCoordinator {
    let now = after(seconds)
    return SharedResultInsertionCoordinator(
      store: SharedResultStore(directory: directory.url), inserter: inserter, now: { now })
  }

  private func saveReady() async throws -> SharedResult {
    let result = SharedResult(
      sessionID: sessionID, text: "明日の会議は10時からです。", createdAt: createdAt)
    try await SharedResultStore(directory: directory.url).save(result, expectedRevision: nil)
    return result
  }

  private func stored() async throws -> SharedResult? {
    try await SharedResultStore(directory: directory.url).load(sessionID: sessionID)
  }

  @Test("iOS-05: 挿入前に本文をプレビューし、明示的な操作までは挿入しない")
  func previewsWithoutInserting() async throws {
    let ready = try await saveReady()
    let inserter = RecordingInserter()

    let preview = try await coordinator(inserter).preview(sessionID: sessionID)

    #expect(preview == .insertable(text: ready.text, expiresAt: ready.expiresAt))
    #expect(inserter.insertedTexts.isEmpty)
    #expect(try await stored() == ready)
  }

  @Test("iOS-IPC-02, iOS-IPC-05: 結果がない・別セッションは挿入せず、期限切れは検出したときに削除する")
  func previewsNonInsertableResults() async throws {
    let inserter = RecordingInserter()
    #expect(try await coordinator(inserter).preview(sessionID: sessionID) == .notFound)

    _ = try await saveReady()
    #expect(try await coordinator(inserter).preview(sessionID: SessionID()) == .notFound)

    let expired = try await coordinator(inserter, at: 600).preview(sessionID: sessionID)
    #expect(expired == .notInsertable(.expired))
    #expect(try await stored() == nil)
  }

  @Test("iAC-04, iOS-IPC-05: 期限切れの結果は挿入せず、挿入操作で検出したときも削除する")
  func insertDeletesExpiredResult() async throws {
    _ = try await saveReady()
    let inserter = RecordingInserter()

    let outcome = try await coordinator(inserter, at: 600).insert(sessionID: sessionID)

    #expect(outcome == .notInserted(.expired))
    #expect(inserter.insertedTexts.isEmpty)
    #expect(try await stored() == nil)
  }

  @Test("iAC-04, iOS-IPC-05: 明示的な挿入操作で1回だけ挿入し、挿入後は共有テキストを削除する")
  func insertsOnceAndDeletesAfterInsertion() async throws {
    let ready = try await saveReady()
    let inserter = RecordingInserter()
    let coordinator = coordinator(inserter)

    #expect(try await coordinator.insert(sessionID: sessionID) == .inserted)
    #expect(try await coordinator.insert(sessionID: sessionID) == .notFound)

    #expect(inserter.insertedTexts == [ready.text])
    #expect(try await stored() == nil)
  }

  @Test("iAC-04: 挿入済みが記録されている結果は挿入しない")
  func doesNotInsertConsumedResult() async throws {
    var consumed = try await saveReady()
    try consumed.beginInsertion(for: sessionID, at: after(1))
    try consumed.markConsumed(at: after(2))
    try await SharedResultStore(directory: directory.url).save(consumed, expectedRevision: 0)
    let inserter = RecordingInserter()

    let outcome = try await coordinator(inserter, at: 3).insert(sessionID: sessionID)

    #expect(outcome == .notInserted(.consumed))
    #expect(inserter.insertedTexts.isEmpty)
  }

  @Test("iAC-04: 挿入ボタンを同時に連打しても、挿入は1回だけ")
  func concurrentTapsInsertOnce() async throws {
    _ = try await saveReady()
    let inserter = RecordingInserter()
    let coordinator = coordinator(inserter)
    let sessionID = sessionID

    let outcomes = await withTaskGroup(of: SharedResultInsertionOutcome?.self) { group in
      for _ in 0..<5 {
        group.addTask { try? await coordinator.insert(sessionID: sessionID) }
      }
      return await group.reduce(into: []) { $0.append($1) }
    }

    #expect(inserter.insertedTexts.count == 1)
    #expect(outcomes.filter { $0 == .inserted }.count == 1)
    #expect(try await stored() == nil)
  }

  @Test("iAC-04: 挿入中にキーボードが再生成されても、別の調整役は挿入しない")
  func regeneratedKeyboardDoesNotInsertWhileInProgress() async throws {
    _ = try await saveReady()
    let directory = directory.url
    let sessionID = sessionID
    let second = RecordingInserter()
    let secondOutcome = Mutex<SharedResultInsertionOutcome?>(nil)
    let now = after(2)
    let first = RecordingInserter {
      let regenerated = SharedResultInsertionCoordinator(
        store: SharedResultStore(directory: directory), inserter: second, now: { now })
      let outcome = try await regenerated.insert(sessionID: sessionID)
      secondOutcome.withLock { $0 = outcome }
    }

    #expect(try await coordinator(first).insert(sessionID: sessionID) == .inserted)
    #expect(secondOutcome.withLock { $0 } == .notInserted(.inProgress))
    #expect(second.insertedTexts.isEmpty)
  }

  @Test("iOS-IPC-03: 挿入を確認できなければ結果不明を記録し、確認なしには再挿入しない")
  func unknownInsertionRequiresConfirmation() async throws {
    let ready = try await saveReady()
    let unconfirmed = RecordingInserter(confirmation: .unknown)

    #expect(try await coordinator(unconfirmed).insert(sessionID: sessionID) == .insertionUnknown)
    #expect(try await stored()?.status == .insertionUnknown)

    let retry = RecordingInserter()
    let later = coordinator(retry, at: 5)
    #expect(
      try await later.preview(sessionID: sessionID)
        == .needsConfirmation(text: ready.text, expiresAt: ready.expiresAt))
    #expect(try await later.insert(sessionID: sessionID) == .notInserted(.needsConfirmation))
    #expect(retry.insertedTexts.isEmpty)

    let confirmed = try await later.insert(sessionID: sessionID, confirmedReinsertion: true)
    #expect(confirmed == .inserted)
    #expect(retry.insertedTexts == [ready.text])
    #expect(try await stored() == nil)
  }

  @Test("iOS-IPC-06: 挿入中に別プロセスが結果不明にしても、読み直して挿入済みを記録する")
  func recordsConsumedAfterConcurrentUpdate() async throws {
    _ = try await saveReady()
    let directory = directory.url
    let sessionID = sessionID
    let interrupted = Mutex(false)
    // 本体アプリの整理が、挿入中の結果を結果不明にした状況を再現する
    let inserter = RecordingInserter {
      let other = SharedResultStore(directory: directory)
      var current = try #require(try await other.load(sessionID: sessionID))
      try current.markInsertionUnknown()
      try await other.save(current, expectedRevision: current.revision - 1)
      interrupted.withLock { $0 = true }
    }

    #expect(try await coordinator(inserter).insert(sessionID: sessionID) == .inserted)
    #expect(interrupted.withLock { $0 })
    // 読み直して挿入済みを記録できた場合だけ、削除まで進む
    #expect(try await stored() == nil)
  }

  @Test("iOS-IPC-05: 挿入中に結果が削除されても、挿入済みとして扱い作り直さない")
  func treatsDeletedResultAsInserted() async throws {
    _ = try await saveReady()
    let directory = directory.url
    let sessionID = sessionID
    let inserter = RecordingInserter {
      try await SharedResultStore(directory: directory).delete(sessionID: sessionID)
    }

    #expect(try await coordinator(inserter).insert(sessionID: sessionID) == .inserted)
    #expect(try await stored() == nil)
  }

  @Test("iOS-IPC-01〜03, iOS-IPC-05: 消した結果は挿入済みと同じく削除し、キーボードでも本体アプリでも使えない")
  func discardMakesResultUnusable() async throws {
    _ = try await saveReady()
    let inserter = RecordingInserter()
    let coordinator = coordinator(inserter)

    #expect(try await coordinator.discard(sessionID: sessionID) == .dismissed)

    #expect(try await stored() == nil)
    #expect(try await coordinator.latestSessionID() == nil)
    #expect(try await coordinator.insert(sessionID: sessionID) == .notFound)
    #expect(inserter.insertedTexts.isEmpty)
    let copier = SharedResultRescueCoordinatorTests.RecordingCopier()
    let now = after(2)
    let rescue = SharedResultRescueCoordinator(
      store: SharedResultStore(directory: directory.url), copier: copier, now: { now })
    #expect(try await rescue.items().items.isEmpty)
    #expect(try await rescue.copy(sessionID: sessionID) == .notFound)
    #expect(copier.copiedTexts.isEmpty)
  }

  @Test("iOS-IPC-03: 挿入中（猶予時間内）の結果は消さず、結果がなければ消さない")
  func discardSkipsInProgressAndMissing() async throws {
    var inserting = try await saveReady()
    try inserting.beginInsertion(for: sessionID, at: after(1))
    try await SharedResultStore(directory: directory.url).save(inserting, expectedRevision: 0)
    let coordinator = coordinator(RecordingInserter(), at: 5)

    #expect(try await coordinator.discard(sessionID: sessionID) == .notDismissed(.inProgress))
    #expect(try await stored() == inserting)
    #expect(try await coordinator.discard(sessionID: SessionID()) == .notFound)
  }

  @Test("iOS-IPC-03: 挿入結果が不明な結果を「入っていた」と確かめたら、挿入し直さずに挿入済みとして削除する")
  func confirmInsertedResolvesUnknownWithoutInserting() async throws {
    _ = try await saveReady()
    let unconfirmed = RecordingInserter(confirmation: .unknown)
    #expect(try await coordinator(unconfirmed).insert(sessionID: sessionID) == .insertionUnknown)
    let later = RecordingInserter()

    let outcome = try await coordinator(later, at: 5).confirmInserted(sessionID: sessionID)

    #expect(outcome == .dismissed)
    #expect(later.insertedTexts.isEmpty)
    #expect(unconfirmed.insertedTexts.count == 1)
    #expect(try await stored() == nil)
  }

  @Test("iOS-IPC-03: 挿入結果が不明でない結果は、「入っていた」で挿入済みにしない")
  func confirmInsertedRequiresUnknownState() async throws {
    let ready = try await saveReady()

    let outcome = try await coordinator(RecordingInserter()).confirmInserted(sessionID: sessionID)

    #expect(outcome == .notDismissed(.insertable))
    #expect(try await stored() == ready)
  }

  @Test(
    "iOS-05, iAC-10: プレビューの文字列表現とリフレクションに本文を出さない",
    arguments: [
      SharedResultPreview.insertable(text: "秘密の本文", expiresAt: .distantFuture),
      .needsConfirmation(text: "秘密の本文", expiresAt: .distantFuture),
    ])
  func previewDescriptionHidesText(_ preview: SharedResultPreview) {
    var dumped = ""
    dump(preview, to: &dumped)
    let outputs = [
      String(describing: preview), String(reflecting: preview),
      String(describing: Mirror(reflecting: preview).children.map(\.value)), dumped,
    ]

    for output in outputs {
      #expect(!output.contains("秘密"))
    }
    #expect(String(describing: preview).contains("length: 5"))
  }
  @Test("iOS-04, iOS-06: キーボードは保存されている結果のうち最も新しいものを待ち、挿入済み・壊れた結果は除く")
  func latestSessionIDPicksNewest() async throws {
    let store = SharedResultStore(directory: directory.url)
    let older = SharedResult(sessionID: SessionID(), text: "古い結果", createdAt: createdAt)
    let newer = SharedResult(
      sessionID: SessionID(), text: "新しい結果", createdAt: after(60))
    var consumed = SharedResult(
      sessionID: SessionID(), text: "挿入済み", createdAt: after(120))
    try consumed.beginInsertion(for: consumed.sessionID, at: after(121))
    try consumed.markConsumed(at: after(122))
    for result in [older, newer, consumed] {
      try await store.save(result, expectedRevision: nil)
    }
    // 壊れた結果（最も新しくても待たない）
    try Data("壊れた".utf8).write(
      to: directory.url.appendingPathComponent("\(SessionID().rawValue.uuidString).json"))

    let latest = try await coordinator(RecordingInserter(), at: 180).latestSessionID()

    #expect(latest == newer.sessionID)
    // 挿入済み・壊れた結果は整理で削除する（iOS-IPC-05）
    #expect(try await store.storedSessionIDs().count == 2)
  }

  @Test("iOS-IPC-06: 作成時刻が現在より後の結果は、後から作られた結果を隠さない")
  func latestSessionIDSkipsFutureResults() async throws {
    let store = SharedResultStore(directory: directory.url)
    let future = SharedResult(sessionID: SessionID(), text: "未来", createdAt: after(3600))
    let current = SharedResult(sessionID: SessionID(), text: "現在", createdAt: createdAt)
    for result in [future, current] {
      try await store.save(result, expectedRevision: nil)
    }

    #expect(
      try await coordinator(RecordingInserter(), at: 10).latestSessionID() == current.sessionID)
  }

  @Test("iOS-IPC-05: 期限切れの結果は整理で削除し、待たない。結果がなければ待つセッションはない")
  func latestSessionIDSkipsExpired() async throws {
    #expect(try await coordinator(RecordingInserter()).latestSessionID() == nil)

    _ = try await saveReady()
    let expiredAt = SharedResultConfiguration.defaultTimeToLive.components.seconds

    #expect(
      try await coordinator(RecordingInserter(), at: TimeInterval(expiredAt)).latestSessionID()
        == nil)
    #expect(try await stored() == nil)
  }

  @Test("iAC-07: 共有コンテナの一覧を読めなければ投げる")
  func latestSessionIDThrowsWhenUnreadable() async throws {
    // ディレクトリの代わりにファイルがあると一覧を読めない
    try Data().write(to: directory.url)

    await #expect(throws: (any Error).self) {
      try await coordinator(RecordingInserter()).latestSessionID()
    }
  }

  @Test(
    "iOS-IPC-03: 挿入前後の文脈から、挿入した本文が入ったかを判定する",
    arguments: [
      // 本文で終わる
      ("こんにちは", "" as String?, "こんにちは" as String?, SharedResultInsertionConfirmation.confirmed),
      ("こんにちは", "前の文。", "前の文。こんにちは", .confirmed),
      // 文脈が本文の末尾だけ（入力欄が現在の行だけを返す）
      ("1行目\n2行目", "", "2行目", .confirmed),
      // 取れない・空・変わらない・別の文字列
      ("こんにちは", nil, nil, .unknown),
      ("こんにちは", "", "", .unknown),
      ("こんにちは", "前の文。", "前の文。", .unknown),
      ("こんにちは", "", "こんばんは", .unknown),
      ("", "前の文。", "前の文。x", .unknown),
    ])
  func confirmationFromContext(
    _ text: String, _ before: String?, _ after: String?,
    _ expected: SharedResultInsertionConfirmation
  ) {
    #expect(
      SharedResultInsertionConfirmation(
        insertedText: text, contextBefore: before, contextAfter: after) == expected)
  }
}
