import Foundation
import Testing
import UtterCore

@testable import UtterPersistence

/// 共有結果を削除した後、App Group の保存先のファイルに本文が残らないことを、ファイルの中身で確かめる（iAC-10）。
///
/// 他のテストは `load(sessionID:)` が `nil` になることで削除を確かめている。ここでは書き込み途中の一時ファイルや
/// ロックファイルも含めて保存先のすべてのファイルを読み、本文の目印が見つからないことを確かめる。
/// 実機の App Group での確認は docs/Phasei3検証-実機継続利用.md の 3-4・3-5 で行う。
struct SharedResultResidueTests {
  private let directory = TemporaryDirectory()
  private let createdAt = Date(timeIntervalSince1970: 1_800_000_000)
  /// 削除される結果の本文。ログ・ファイルから検索できるよう目印を含める
  private static let removedText = "UTTERDUMMY0001 ユーターけんしょう いち"
  /// 残る結果の本文
  private static let keptText = "UTTERDUMMY0002 ユーターけんしょう に"

  /// 本文の挿入を常に確認できたことにする
  struct ConfirmingInserter: SharedResultTextInserter {
    func insert(_ text: String) async -> SharedResultInsertionConfirmation { .confirmed }
  }

  /// 結果を削除する経路
  enum Removal: CaseIterable, Sendable {
    /// 本体アプリの起動時・キーボードの表示時の整理（期限切れ）
    case cleanUpExpired
    /// 整理（挿入済み）
    case cleanUpConsumed
    /// キーボードのプレビューで期限切れを検出
    case previewExpired
    /// 挿入操作で期限切れを検出
    case insertExpired
    /// 挿入して挿入済みを記録
    case inserted
  }

  private func after(_ seconds: TimeInterval) -> Date {
    createdAt.addingTimeInterval(seconds)
  }

  private var store: SharedResultStore {
    SharedResultStore(directory: directory.url)
  }

  /// 保存先のすべてのファイル（隠しファイル・サブディレクトリを含む）
  private func storedFiles() throws -> [URL] {
    let enumerator = try #require(
      FileManager.default.enumerator(
        at: directory.url, includingPropertiesForKeys: [.isRegularFileKey]))
    return try enumerator.compactMap { $0 as? URL }.filter {
      try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
    }
  }

  /// 本文の目印を含むファイルの数。一致した中身は表示しない
  private func filesContaining(_ text: String) throws -> Int {
    let marker = Data(text.utf8)
    return try storedFiles().filter { try Data(contentsOf: $0).range(of: marker) != nil }.count
  }

  private func remove(_ result: SharedResult, by removal: Removal) async throws {
    let sessionID = result.sessionID
    switch removal {
    case .cleanUpExpired:
      #expect(try await store.cleanUp(at: after(600)).removedCount == 1)
    case .cleanUpConsumed:
      var consumed = result
      try consumed.beginInsertion(for: sessionID, at: after(1))
      try consumed.markConsumed(at: after(2))
      try await store.save(consumed, expectedRevision: result.revision)
      #expect(try await store.cleanUp(at: after(3)).removedCount == 1)
    case .previewExpired:
      let coordinator = SharedResultInsertionCoordinator(
        store: store, inserter: ConfirmingInserter(),
        now: { [createdAt] in
          createdAt.addingTimeInterval(600)
        })
      #expect(try await coordinator.preview(sessionID: sessionID) == .notInsertable(.expired))
    case .insertExpired:
      let coordinator = SharedResultInsertionCoordinator(
        store: store, inserter: ConfirmingInserter(),
        now: { [createdAt] in
          createdAt.addingTimeInterval(600)
        })
      #expect(try await coordinator.insert(sessionID: sessionID) == .notInserted(.expired))
    case .inserted:
      let coordinator = SharedResultInsertionCoordinator(
        store: store, inserter: ConfirmingInserter(),
        now: { [createdAt] in
          createdAt.addingTimeInterval(1)
        })
      #expect(try await coordinator.insert(sessionID: sessionID) == .inserted)
    }
  }

  @Test("iOS-IPC-01, iOS-IPC-04: 保存ファイルの項目は共有結果の項目だけで、ほかに中身のあるファイルを作らない")
  func storedFileHoldsOnlyResultFields() async throws {
    let result = SharedResult(sessionID: SessionID(), text: Self.keptText, createdAt: createdAt)
    try await store.save(result, expectedRevision: nil)

    let files = try storedFiles()
    let resultFiles = files.filter { $0.pathExtension == "json" }
    #expect(
      resultFiles.map(\.lastPathComponent) == ["\(result.sessionID.rawValue.uuidString).json"])
    // 結果のファイル以外は、中身が空のロックファイルだけ
    for file in files where file.pathExtension != "json" {
      #expect(file.pathExtension == "lock")
      #expect(try Data(contentsOf: file).isEmpty)
    }
    // 項目名だけを比べる。API キー・トークン・音声の項目が加わったら気づけるようにする
    let file = try #require(resultFiles.first)
    let object = try #require(
      try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    #expect(
      Set(object.keys) == [
        "sessionID", "createdAt", "expiresAt", "status", "text", "revision", "configuration",
      ])
  }

  @Test("iAC-10, iOS-IPC-05: 期限切れ・挿入後に削除した結果の本文は、保存先のどのファイルにも残らない", arguments: Removal.allCases)
  func removedTextDoesNotRemainInFiles(_ removal: Removal) async throws {
    let removed = SharedResult(sessionID: SessionID(), text: Self.removedText, createdAt: createdAt)
    // 残る結果は期限を長くし、どの経路でも削除されないようにする
    let kept = SharedResult(
      sessionID: SessionID(), text: Self.keptText, createdAt: createdAt,
      configuration: try SharedResultConfiguration(timeToLive: .seconds(3_600)))
    try await store.save(removed, expectedRevision: nil)
    try await store.save(kept, expectedRevision: nil)
    #expect(try filesContaining(Self.removedText) == 1)

    try await remove(removed, by: removal)

    #expect(try filesContaining(Self.removedText) == 0)
    // 検索が働いていることを、残した結果の本文が見つかることで確かめる
    #expect(try filesContaining(Self.keptText) == 1)
    #expect(try await store.load(sessionID: removed.sessionID) == nil)
    #expect(try await store.load(sessionID: kept.sessionID) == kept)
  }
}
