import Foundation
import Testing
import UtterCore
import UtterPersistence

@testable import UtteriOSKit

struct SharedResultStorageTests {
  private let appLocal = TemporaryDirectory()
  private let appGroup = TemporaryDirectory()
  private let createdAt = Date(timeIntervalSince1970: 1_800_000_000)

  /// 保存した結果がどちらのディレクトリに書かれたか確かめる
  private func save(to storage: SharedResultStorage) async throws -> SessionID {
    let sessionID = SessionID()
    try await storage.store.save(
      SharedResult(sessionID: sessionID, text: "本文", createdAt: createdAt),
      expectedRevision: nil)
    return sessionID
  }

  private func contains(_ sessionID: SessionID, in directory: URL) -> Bool {
    FileManager.default.fileExists(
      atPath: directory.appendingPathComponent("\(sessionID.rawValue.uuidString).json").path)
  }

  @Test(
    "iOS-IPC-01, iOS-07: App Group ID が未設定なら、アプリ内にだけ保存してキーボードと共有しない",
    arguments: [nil, "", "  \n"] as [String?])
  func notConfigured(_ identifier: String?) async throws {
    var opened: [String] = []
    let storage = SharedResultStorage.resolve(
      appGroupIdentifier: identifier, appLocalDirectory: appLocal.url,
      makeAppGroupStore: {
        opened.append($0)
        return SharedResultStore(directory: appGroup.url)
      })

    #expect(storage.sharing == .appLocalOnly(.appGroupNotConfigured))
    #expect(opened.isEmpty)
    let sessionID = try await save(to: storage)
    #expect(contains(sessionID, in: appLocal.url))
    #expect(!contains(sessionID, in: appGroup.url))
  }

  @Test("iOS-IPC-01: App Group ID を設定してコンテナを開ければ、App Group に保存してキーボードと共有する")
  func appGroup() async throws {
    var opened: [String] = []
    let storage = SharedResultStorage.resolve(
      appGroupIdentifier: " group.example.utter ", appLocalDirectory: appLocal.url,
      makeAppGroupStore: {
        opened.append($0)
        return SharedResultStore(directory: appGroup.url)
      })

    #expect(storage.sharing == .appGroup)
    #expect(opened == ["group.example.utter"])
    let sessionID = try await save(to: storage)
    #expect(contains(sessionID, in: appGroup.url))
    #expect(!contains(sessionID, in: appLocal.url))
  }

  @Test("iOS-07: App Group ID を設定してもコンテナを開けなければ、アプリ内に保存して共有しない")
  func appGroupUnavailable() async throws {
    let storage = SharedResultStorage.resolve(
      appGroupIdentifier: "group.example.utter", appLocalDirectory: appLocal.url,
      makeAppGroupStore: { _ in nil })

    #expect(storage.sharing == .appLocalOnly(.appGroupUnavailable))
    let sessionID = try await save(to: storage)
    #expect(contains(sessionID, in: appLocal.url))
  }
}
