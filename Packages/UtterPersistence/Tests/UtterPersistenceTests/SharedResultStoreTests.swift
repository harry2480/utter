import Foundation
import Testing
import UtterCore

@testable import UtterPersistence

struct SharedResultStoreTests {
  private let directory = TemporaryDirectory()
  private let sessionID = SessionID()
  private let createdAt = Date(timeIntervalSince1970: 1_800_000_000)

  private func result() -> SharedResult {
    SharedResult(sessionID: sessionID, text: "本文", createdAt: createdAt)
  }

  @Test("iOS-IPC-04: 保存した結果を読み込める")
  func savesAndLoads() async throws {
    let store = SharedResultStore(directory: directory.url)
    try await store.save(result(), expectedRevision: nil)

    #expect(try await store.load(sessionID: sessionID) == result())
  }

  @Test("iOS-IPC-04: 別プロセスが更新した結果を読み込み直す")
  func loadReflectsUpdatesFromAnotherStore() async throws {
    let app = SharedResultStore(directory: directory.url)
    let keyboard = SharedResultStore(directory: directory.url)
    try await app.save(result(), expectedRevision: nil)
    #expect(try await app.load(sessionID: sessionID)?.status == .ready)

    var inserting = try #require(try await keyboard.load(sessionID: sessionID))
    try inserting.beginInsertion(for: sessionID, at: createdAt.addingTimeInterval(1))
    try await keyboard.save(inserting, expectedRevision: 0)

    #expect(try await app.load(sessionID: sessionID)?.revision == 1)
  }

  @Test("iOS-IPC-03: 古い revision から作った結果の保存は拒否し、先に保存した状態を残す")
  func rejectsSaveFromStaleRevision() async throws {
    let app = SharedResultStore(directory: directory.url)
    let keyboard = SharedResultStore(directory: directory.url)
    try await app.save(result(), expectedRevision: nil)

    let loadedByApp = try #require(try await app.load(sessionID: sessionID))
    var loadedByKeyboard = try #require(try await keyboard.load(sessionID: sessionID))
    try loadedByKeyboard.beginInsertion(for: sessionID, at: createdAt.addingTimeInterval(1))
    try await keyboard.save(loadedByKeyboard, expectedRevision: 0)

    var stale = loadedByApp
    try stale.beginInsertion(for: sessionID, at: createdAt.addingTimeInterval(2))
    await #expect(throws: SharedResultStoreError.revisionConflict) {
      try await app.save(stale, expectedRevision: loadedByApp.revision)
    }
    #expect(try await app.load(sessionID: sessionID) == loadedByKeyboard)
  }

  @Test("iOS-IPC-03: 保存済みの revision を指定しても、revision が進んでいない結果では巻き戻さない")
  func rejectsSaveWithoutAdvancingRevision() async throws {
    let store = SharedResultStore(directory: directory.url)
    let ready = result()
    try await store.save(ready, expectedRevision: nil)
    var inserting = ready
    try inserting.beginInsertion(for: sessionID, at: createdAt.addingTimeInterval(1))
    try await store.save(inserting, expectedRevision: 0)

    for stale in [ready, inserting] {
      await #expect(throws: SharedResultStoreError.revisionConflict) {
        try await store.save(stale, expectedRevision: inserting.revision)
      }
    }
    #expect(try await store.load(sessionID: sessionID) == inserting)
  }

  @Test("iOS-IPC-04: 保存済みの結果があるときに新規として保存しない")
  func rejectsCreatingOverExistingResult() async throws {
    let store = SharedResultStore(directory: directory.url)
    try await store.save(result(), expectedRevision: nil)

    await #expect(throws: SharedResultStoreError.revisionConflict) {
      try await store.save(result(), expectedRevision: nil)
    }
  }

  @Test("iOS-IPC-04: 削除した結果は読み込めず、存在しない結果の削除はエラーにしない")
  func deletes() async throws {
    let store = SharedResultStore(directory: directory.url)
    try await store.save(result(), expectedRevision: nil)
    try await store.delete(sessionID: sessionID)

    #expect(try await store.load(sessionID: sessionID) == nil)
    try await store.delete(sessionID: sessionID)
  }
}
