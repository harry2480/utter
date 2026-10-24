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

    #expect(preview == .insertable(text: ready.text))
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
    #expect(try await later.preview(sessionID: sessionID) == .needsConfirmation(text: ready.text))
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

  @Test(
    "iOS-05, iAC-10: プレビューの文字列表現とリフレクションに本文を出さない",
    arguments: [
      SharedResultPreview.insertable(text: "秘密の本文"), .needsConfirmation(text: "秘密の本文"),
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
}
