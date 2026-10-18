import Foundation
import Synchronization
import Testing
import UtterCore

@testable import UtterPersistence

struct SharedResultRescueCoordinatorTests {
  private let directory = TemporaryDirectory()
  private let sessionID = SessionID()
  private let createdAt = Date(timeIntervalSince1970: 1_800_000_000)
  private let text = "明日の会議は10時からです。"

  /// コピーした本文を記録する
  final class RecordingCopier: SharedResultTextCopier {
    private let copied = Mutex<[String]>([])

    var copiedTexts: [String] { copied.withLock { $0 } }

    func copy(_ text: String) async {
      copied.withLock { $0.append(text) }
    }
  }

  /// 本文を記録し、挿入を確認できたとして返す
  final class ConfirmingInserter: SharedResultTextInserter {
    private let inserted = Mutex<[String]>([])

    var insertedTexts: [String] { inserted.withLock { $0 } }

    func insert(_ text: String) async -> SharedResultInsertionConfirmation {
      inserted.withLock { $0.append(text) }
      return .confirmed
    }
  }

  private var store: SharedResultStore { SharedResultStore(directory: directory.url) }

  private func after(_ seconds: TimeInterval) -> Date {
    createdAt.addingTimeInterval(seconds)
  }

  private func coordinator(
    _ copier: RecordingCopier, at seconds: TimeInterval = 1
  ) -> SharedResultRescueCoordinator {
    let now = after(seconds)
    return SharedResultRescueCoordinator(store: store, copier: copier, now: { now })
  }

  @discardableResult
  private func saveReady(
    sessionID: SessionID? = nil, text: String? = nil, createdAt: Date? = nil
  ) async throws -> SharedResult {
    let result = SharedResult(
      sessionID: sessionID ?? self.sessionID, text: text ?? self.text,
      createdAt: createdAt ?? self.createdAt)
    try await store.save(result, expectedRevision: nil)
    return result
  }

  /// 保存済みの結果の状態を進める
  private func update(
    _ sessionID: SessionID? = nil, _ body: (inout SharedResult) throws -> Void
  ) async throws {
    let sessionID = sessionID ?? self.sessionID
    var result = try #require(try await store.load(sessionID: sessionID))
    let revision = result.revision
    try body(&result)
    try await store.save(result, expectedRevision: revision)
  }

  private func stored(_ sessionID: SessionID? = nil) async throws -> SharedResult? {
    try await store.load(sessionID: sessionID ?? self.sessionID)
  }

  @Test("iOS-07: 未挿入の結果を、本文つきで新しい順に一覧にする")
  func listsNotInsertedResultsNewestFirst() async throws {
    try await saveReady()
    let newer = SessionID()
    try await saveReady(sessionID: newer, text: "新しい結果", createdAt: after(1))

    let list = try await coordinator(RecordingCopier(), at: 2).items()

    #expect(
      list.items == [
        SharedResultRescueItem(
          sessionID: newer, createdAt: after(1), expiresAt: after(601),
          state: .notInserted(text: "新しい結果")),
        SharedResultRescueItem(
          sessionID: sessionID, createdAt: createdAt, expiresAt: after(600),
          state: .notInserted(text: text)),
      ])
    #expect(list.unavailableCount == 0)
  }

  @Test("iOS-07, iOS-IPC-03: 挿入結果が不明な結果は本文つきで示し、挿入中（猶予時間内）は本文を出さない")
  func listsUnknownAndInProgressResults() async throws {
    try await saveReady()
    try await update { try $0.beginInsertion(for: sessionID, at: after(1)) }

    let inProgress = try await coordinator(RecordingCopier(), at: 2).items()
    #expect(inProgress.items.map(\.state) == [.inserting])

    // 猶予時間を過ぎても挿入中のまま（拡張の強制終了）なら、挿入結果不明として示す
    let stale = try await coordinator(RecordingCopier(), at: 40).items()
    #expect(stale.items.map(\.state) == [.insertionUnknown(text: text)])

    try await update { try $0.markInsertionUnknown() }
    let unknown = try await coordinator(RecordingCopier(), at: 41).items()
    #expect(unknown.items.map(\.state) == [.insertionUnknown(text: text)])
    #expect(try await stored() != nil)
  }

  @Test("iOS-07, iOS-IPC-05: 期限切れ・挿入済みの結果は本文を出さずに状態を示し、共有テキストを削除する")
  func listsExpiredAndInsertedWithoutText() async throws {
    try await saveReady()
    let inserted = SessionID()
    try await saveReady(sessionID: inserted, createdAt: after(100))
    try await update(inserted) {
      try $0.beginInsertion(for: inserted, at: after(101))
      try $0.markConsumed(at: after(102))
    }
    let unknown = SessionID()
    try await saveReady(sessionID: unknown, createdAt: after(-100))
    try await update(unknown) {
      try $0.beginInsertion(for: unknown, at: after(-99))
      try $0.markInsertionUnknown()
    }

    let list = try await coordinator(RecordingCopier(), at: 600).items()

    #expect(list.items.map(\.state) == [.inserted, .expired, .expired])
    for item in list.items {
      #expect(!String(describing: item).contains(text))
    }
    #expect(try await stored() == nil)
    #expect(try await stored(inserted) == nil)
    #expect(try await stored(unknown) == nil)
  }

  @Test("iOS-07: 端末の時刻が作成時より前なら、本文を出さず削除もしない")
  func listsInvalidTimestampWithoutText() async throws {
    try await saveReady()

    let list = try await coordinator(RecordingCopier(), at: -1).items()

    #expect(list.items.map(\.state) == [.invalidTimestamp])
    #expect(try await stored() != nil)
  }

  @Test("iOS-07: 結果がなければ空の一覧、壊れた結果は一覧に出さない")
  func skipsMissingAndCorruptedResults() async throws {
    #expect(try await coordinator(RecordingCopier()).items().items.isEmpty)

    try await saveReady()
    let corrupted = SessionID()
    try Data("{".utf8).write(
      to: directory.url.appendingPathComponent("\(corrupted.rawValue.uuidString).json"))
    // 保存時の形（大文字）でないファイル名は読めないため一覧に出さない
    try Data("{}".utf8).write(
      to: directory.url.appendingPathComponent(
        "\(SessionID().rawValue.uuidString.lowercased()).json"))

    let list = try await coordinator(RecordingCopier()).items()

    #expect(list.items.map(\.sessionID) == [sessionID])
    #expect(list.unavailableCount == 0)
  }

  @Test("iOS-07, iOS-IPC-05: 読めない結果は数だけを示し、変更しない")
  func countsUnavailableResults() async throws {
    try await saveReady()
    let url = directory.url.appendingPathComponent("\(sessionID.rawValue.uuidString).json")
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    let list = try await coordinator(RecordingCopier()).items()

    #expect(list.items.isEmpty)
    #expect(list.unavailableCount == 1)
    #expect(FileManager.default.fileExists(atPath: url.path))
  }

  @Test("iOS-07, iOS-IPC-05: コピーした結果はキーボードから挿入できず、共有テキストを削除する")
  func copyConsumesAndDeletes() async throws {
    try await saveReady()
    let copier = RecordingCopier()
    let coordinator = coordinator(copier)

    #expect(try await coordinator.copy(sessionID: sessionID) == .copied)
    #expect(try await coordinator.copy(sessionID: sessionID) == .notFound)

    #expect(copier.copiedTexts == [text])
    #expect(try await stored() == nil)
    let inserter = ConfirmingInserter()
    let later = after(2)
    let keyboard = SharedResultInsertionCoordinator(
      store: store, inserter: inserter, now: { later })
    #expect(try await keyboard.insert(sessionID: sessionID) == .notFound)
    #expect(inserter.insertedTexts.isEmpty)
  }

  @Test("iOS-07, iOS-IPC-03: 挿入結果が不明な結果も、期限内ならコピーできる")
  func copiesUnknownResult() async throws {
    try await saveReady()
    try await update {
      try $0.beginInsertion(for: sessionID, at: after(1))
      try $0.markInsertionUnknown()
    }
    let copier = RecordingCopier()

    #expect(try await coordinator(copier, at: 5).copy(sessionID: sessionID) == .copied)
    #expect(copier.copiedTexts == [text])
    #expect(try await stored() == nil)
  }

  @Test("iOS-07, iOS-IPC-05: 期限切れの結果はコピーせず、検出したときに削除する")
  func copyRejectsExpiredResult() async throws {
    try await saveReady()
    let copier = RecordingCopier()

    #expect(
      try await coordinator(copier, at: 600).copy(sessionID: sessionID) == .notCopied(.expired))
    #expect(copier.copiedTexts.isEmpty)
    #expect(try await stored() == nil)
  }

  @Test("iOS-07, iOS-IPC-03: キーボードが挿入中（猶予時間内）の結果はコピーせず、残す")
  func copyRejectsInProgressResult() async throws {
    try await saveReady()
    try await update { try $0.beginInsertion(for: sessionID, at: after(1)) }
    let copier = RecordingCopier()

    let outcome = try await coordinator(copier, at: 2).copy(sessionID: sessionID)

    #expect(outcome == .notCopied(.inProgress))
    #expect(copier.copiedTexts.isEmpty)
    #expect(try await stored() != nil)
  }

  @Test("iOS-07, iOS-IPC-03: コピーとキーボードの挿入を同時に行っても、どちらか一方だけになる")
  func copyAndInsertAreExclusive() async throws {
    try await saveReady()
    let copier = RecordingCopier()
    let inserter = ConfirmingInserter()
    let rescue = coordinator(copier)
    let now = after(1)
    let keyboard = SharedResultInsertionCoordinator(
      store: store, inserter: inserter, now: { now })
    let sessionID = sessionID

    async let copied = try? rescue.copy(sessionID: sessionID)
    async let inserted = try? keyboard.insert(sessionID: sessionID)
    let outcomes = await (copied, inserted)

    #expect(copier.copiedTexts.count + inserter.insertedTexts.count == 1)
    #expect((outcomes.0 == .copied) != (outcomes.1 == .inserted))
  }

  @Test("iOS-07: コピーを同時に連打しても、コピーは1回だけ")
  func concurrentCopiesCopyOnce() async throws {
    try await saveReady()
    let copier = RecordingCopier()
    let coordinator = coordinator(copier)
    let sessionID = sessionID

    let outcomes = await withTaskGroup(of: SharedResultCopyOutcome?.self) { group in
      for _ in 0..<5 {
        group.addTask { try? await coordinator.copy(sessionID: sessionID) }
      }
      return await group.reduce(into: []) { $0.append($1) }
    }

    #expect(copier.copiedTexts.count == 1)
    #expect(outcomes.filter { $0 == .copied }.count == 1)
  }

  private func dumped(_ value: some Any) -> String {
    var output = ""
    dump(value, to: &output)
    return output
  }

  @Test("iOS-07: 救済画面の状態と項目の文字列表現・リフレクションに本文を出さない")
  func descriptionsHideText() {
    let item = SharedResultRescueItem(
      sessionID: sessionID, createdAt: createdAt, expiresAt: after(600),
      state: .insertionUnknown(text: "秘密の本文"))
    let outputs = [
      String(describing: item),
      String(reflecting: item),
      String(describing: item.state),
      String(reflecting: item.state),
      String(describing: Mirror(reflecting: item.state).children.map(\.value)),
      dumped(item),
      dumped(item.state),
      String(describing: Mirror(reflecting: item).children.map(\.value)),
    ]

    for output in outputs {
      #expect(!output.contains("秘密"))
    }
  }
}
