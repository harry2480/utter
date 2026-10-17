import Foundation
import Testing
import UtterCore

@testable import UtterPersistence

struct SharedResultCleanUpTests {
  private let directory = TemporaryDirectory()
  private let createdAt = Date(timeIntervalSince1970: 1_800_000_000)

  private func after(_ seconds: TimeInterval) -> Date {
    createdAt.addingTimeInterval(seconds)
  }

  /// 既定の設定（有効期限10分、挿入の猶予30秒）で作った結果
  private func ready(_ sessionID: SessionID = SessionID()) -> SharedResult {
    SharedResult(sessionID: sessionID, text: "本文", createdAt: createdAt)
  }

  private func inserting(at seconds: TimeInterval) throws -> SharedResult {
    var result = ready()
    try result.beginInsertion(for: result.sessionID, at: after(seconds))
    return result
  }

  private func save(_ results: SharedResult..., in store: SharedResultStore) async throws {
    for result in results {
      try await store.save(result, expectedRevision: nil)
    }
  }

  @Test("iOS-IPC-05: 挿入済みの結果と期限切れの結果は削除し、期限内の結果は残す")
  func removesConsumedAndExpiredResults() async throws {
    let store = SharedResultStore(directory: directory.url)
    var consumed = try inserting(at: 1)
    try consumed.markConsumed(at: after(2))
    let expired = ready()
    let fresh = ready()
    try await save(consumed, fresh, in: store)
    try await store.save(expired, expectedRevision: nil)

    // fresh と expired は同じ作成時刻なので、期限の判定は時刻で分ける
    let reportBeforeExpiry = try await store.cleanUp(at: after(599))
    #expect(reportBeforeExpiry == SharedResultCleanUpReport(removedCount: 1))
    #expect(try await store.load(sessionID: consumed.sessionID) == nil)
    #expect(try await store.load(sessionID: fresh.sessionID) == fresh)

    let reportAfterExpiry = try await store.cleanUp(at: after(600))
    #expect(reportAfterExpiry == SharedResultCleanUpReport(removedCount: 2))
    #expect(try await store.load(sessionID: fresh.sessionID) == nil)
    #expect(try await store.load(sessionID: expired.sessionID) == nil)
  }

  @Test("iOS-IPC-06: 再起動後、猶予時間を過ぎた挿入中の結果は挿入結果不明にし、自動では再挿入できない")
  func recoversInterruptedInsertionWithoutAutoReinsert() async throws {
    let interrupted = try inserting(at: 1)
    try await save(interrupted, in: SharedResultStore(directory: directory.url))

    // 拡張の強制終了や再起動の後に、新しく開き直した保存層で整理する
    let restarted = SharedResultStore(directory: directory.url)
    let report = try await restarted.cleanUp(at: after(32))

    #expect(report == SharedResultCleanUpReport(markedInsertionUnknownCount: 1))
    var recovered = try #require(try await restarted.load(sessionID: interrupted.sessionID))
    #expect(recovered.status == .insertionUnknown)
    #expect(recovered.revision == interrupted.revision + 1)
    #expect(
      recovered.insertability(for: interrupted.sessionID, at: after(33)) == .needsConfirmation)
    #expect(throws: SharedResultError.self) {
      try recovered.beginInsertion(for: interrupted.sessionID, at: after(33))
    }
  }

  @Test("iOS-IPC-06: 猶予時間内の挿入中の結果と、挿入結果不明の結果は変更しない")
  func keepsInProgressAndUnknownResults() async throws {
    let store = SharedResultStore(directory: directory.url)
    let inProgress = try inserting(at: 10)
    var unknown = try inserting(at: 1)
    try unknown.markInsertionUnknown()
    try await save(inProgress, unknown, in: store)

    let report = try await store.cleanUp(at: after(20))

    #expect(report == SharedResultCleanUpReport())
    #expect(try await store.load(sessionID: inProgress.sessionID) == inProgress)
    #expect(try await store.load(sessionID: unknown.sessionID) == unknown)
  }

  @Test("iOS-IPC-06: 読み込めない（壊れた）結果は削除する")
  func removesCorruptedResult() async throws {
    let store = SharedResultStore(directory: directory.url)
    let sessionID = SessionID()
    try FileManager.default.createDirectory(at: directory.url, withIntermediateDirectories: true)
    try Data("{".utf8).write(
      to: directory.url.appendingPathComponent("\(sessionID.rawValue.uuidString).json"))

    let report = try await store.cleanUp(at: after(1))

    #expect(report == SharedResultCleanUpReport(removedCount: 1))
    #expect(try await store.load(sessionID: sessionID) == nil)
  }

  @Test("iOS-IPC-06: ファイル名と中身のセッションが食い違う結果は壊れた結果として削除する")
  func removesResultWithMismatchedSessionID() async throws {
    let store = SharedResultStore(directory: directory.url)
    let interrupted = try inserting(at: 1)
    try await save(interrupted, in: store)
    let renamed = SessionID()
    try FileManager.default.moveItem(
      at: directory.url.appendingPathComponent("\(interrupted.sessionID.rawValue.uuidString).json"),
      to: directory.url.appendingPathComponent("\(renamed.rawValue.uuidString).json"))

    await #expect(throws: SharedResultStoreError.corruptedResult) {
      try await store.load(sessionID: renamed)
    }
    #expect(try await store.cleanUp(at: after(32)) == SharedResultCleanUpReport(removedCount: 1))
    #expect(try await store.load(sessionID: renamed) == nil)
  }

  @Test("iOS-IPC-02: 端末の時刻が作成時より前なら、期限を判定できないため削除しない")
  func keepsResultWhenClockMovedBackwards() async throws {
    let store = SharedResultStore(directory: directory.url)
    let result = ready()
    try await save(result, in: store)

    let report = try await store.cleanUp(at: after(-86_400))

    #expect(report == SharedResultCleanUpReport())
    #expect(try await store.load(sessionID: result.sessionID) == result)
  }

  @Test("iOS-IPC-05: 保存先がまだないときの整理は何もしない")
  func cleanUpWithoutDirectory() async throws {
    let store = SharedResultStore(directory: directory.url.appendingPathComponent("missing"))

    #expect(try await store.cleanUp(at: after(1)) == SharedResultCleanUpReport())
  }

  @Test("iOS-IPC-05: 読めない結果（ロック中など）は専用のエラーにし、整理では変更せずに残す")
  func reportsAccessDeniedAndSkipsInCleanUp() async throws {
    let store = SharedResultStore(directory: directory.url)
    var consumed = try inserting(at: 1)
    try consumed.markConsumed(at: after(2))
    try await save(consumed, in: store)
    let url = directory.url.appendingPathComponent("\(consumed.sessionID.rawValue.uuidString).json")
    // ファイル保護で読めない状態の代わりに、読み取り権限を外す
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    await #expect(throws: SharedResultStoreError.fileAccessDenied) {
      try await store.load(sessionID: consumed.sessionID)
    }
    #expect(try await store.cleanUp(at: after(3)) == SharedResultCleanUpReport(skippedCount: 1))
    #expect(FileManager.default.fileExists(atPath: url.path))
  }

  @Test(
    "iOS-IPC-05: ファイル保護クラスを書き込みオプションに対応させる",
    arguments: [
      (SharedResultFileProtection.complete, Data.WritingOptions.completeFileProtection),
      (.completeUnlessOpen, .completeFileProtectionUnlessOpen),
      (.completeUntilFirstUserAuthentication, .completeFileProtectionUntilFirstUserAuthentication),
      (.none, .noFileProtection),
    ])
  func mapsFileProtection(
    _ protection: SharedResultFileProtection, _ option: Data.WritingOptions
  ) {
    #expect(protection.writingOption == option)
  }

  // .complete / .completeUnlessOpen は macOS ではロック状態に関係なく読み書きが拒否されることがあるため、
  // 実際の挙動は iOS 実機の検証手順で確認する（AC-19）
  @Test(
    "iOS-IPC-05: ファイル保護クラスを指定しても保存・読み込みできる",
    arguments: [SharedResultFileProtection.completeUntilFirstUserAuthentication, .none])
  func savesWithFileProtection(_ protection: SharedResultFileProtection) async throws {
    let store = SharedResultStore(directory: directory.url, fileProtection: protection)
    let result = ready()

    try await store.save(result, expectedRevision: nil)

    #expect(try await store.load(sessionID: result.sessionID) == result)
  }

  @Test("iOS-IPC-06: 値が矛盾した結果は壊れた結果として扱い、整理で削除して残りの整理を続ける")
  func removesInconsistentResultAndContinues() async throws {
    let store = SharedResultStore(directory: directory.url)
    var consumed = try inserting(at: 1)
    try consumed.markConsumed(at: after(2))
    try await save(consumed, in: store)

    // 有効期限の設定が0秒（独自の復号で拒否される）の結果
    let broken = SessionID()
    let json = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(ready(broken)))
    var object = try #require(json as? [String: Any])
    object["configuration"] = ["timeToLive": 0, "insertionGracePeriod": 30]
    try JSONSerialization.data(withJSONObject: object).write(
      to: directory.url.appendingPathComponent("\(broken.rawValue.uuidString).json"))

    await #expect(throws: SharedResultStoreError.corruptedResult) {
      try await store.load(sessionID: broken)
    }
    #expect(try await store.cleanUp(at: after(3)) == SharedResultCleanUpReport(removedCount: 2))
    #expect(try await store.load(sessionID: broken) == nil)
    #expect(try await store.load(sessionID: consumed.sessionID) == nil)
  }
}
