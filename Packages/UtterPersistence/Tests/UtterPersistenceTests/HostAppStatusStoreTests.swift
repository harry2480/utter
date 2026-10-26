import Foundation
import Testing
import UtterCore

@testable import UtterPersistence

struct HostAppStatusStoreTests {
  private let directory = TemporaryDirectory()
  private let status = HostAppStatus(
    observedAt: Date(timeIntervalSince1970: 1_800_000_000), deniedPermissions: [.microphone],
    speechModel: .notDownloaded, usesCloudRefinement: true)

  @Test("iAC-07: 本体アプリが残した状態をキーボードが読める。残していなければ nil")
  func saveAndLoad() async throws {
    let store = HostAppStatusStore(directory: directory.url)
    #expect(try await store.load() == nil)

    try await store.save(status)

    #expect(try await HostAppStatusStore(directory: directory.url).load() == status)
  }

  @Test("iAC-07: 残し直すと前の状態を置き換え、削除すると読めなくなる")
  func replaceAndDelete() async throws {
    let store = HostAppStatusStore(directory: directory.url)
    try await store.save(status)
    var updated = status
    updated.deniedPermissions = []
    updated.speechModel = .ready

    try await store.save(updated)
    #expect(try await store.load() == updated)

    try await store.delete()
    #expect(try await store.load() == nil)
    try await store.delete()
  }

  @Test("iAC-07: 復号できない状態は壊れた値として投げる")
  func corrupted() async throws {
    let store = HostAppStatusStore(directory: directory.url)
    try await store.save(status)
    let file = try #require(
      FileManager.default.contentsOfDirectory(at: directory.url, includingPropertiesForKeys: nil)
        .first)
    try Data("{}".utf8).write(to: file)

    await #expect(throws: SharedResultStoreError.corruptedResult) {
      try await store.load()
    }
  }
}
