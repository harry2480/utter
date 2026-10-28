import Foundation
import Testing
import UtterCore

@testable import UtterPersistence

struct KeyboardSetupReportStoreTests {
  private let directory = TemporaryDirectory()
  private let report = KeyboardSetupReport(
    observedAt: Date(timeIntervalSince1970: 1_800_000_000), hasFullAccess: false)

  @Test("#200: キーボードが残した報告を本体アプリが読める。残していなければ nil")
  func saveAndLoad() async throws {
    let store = KeyboardSetupReportStore(directory: directory.url)
    #expect(try await store.load() == nil)

    try await store.save(report)

    #expect(try await KeyboardSetupReportStore(directory: directory.url).load() == report)
  }

  @Test("#200: 残し直すと前の報告を置き換える")
  func replace() async throws {
    let store = KeyboardSetupReportStore(directory: directory.url)
    try await store.save(report)
    var updated = report
    updated.observedAt = report.observedAt.addingTimeInterval(60)
    updated.hasFullAccess = true

    try await store.save(updated)

    #expect(try await store.load() == updated)
  }

  @Test("#200: 復号できない報告は壊れた値として投げる")
  func corrupted() async throws {
    let store = KeyboardSetupReportStore(directory: directory.url)
    try await store.save(report)
    let file = try #require(
      FileManager.default.contentsOfDirectory(at: directory.url, includingPropertiesForKeys: nil)
        .first)
    try Data("{}".utf8).write(to: file)

    await #expect(throws: SharedResultStoreError.corruptedResult) {
      try await store.load()
    }
  }
}
