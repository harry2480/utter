import Foundation
import Testing

@testable import UtterPersistence

/// キーボードが本体アプリを開く URL の読み分けと、待機の開始の要求（iOS-03・iOS-04, #267）。
struct HostAppLaunchRequestTests {
  private static let requestID = UUID(uuidString: "6F1C2E8A-3B4D-4E5F-8A9B-0C1D2E3F4A5B")!
  private let directory = TemporaryDirectory()
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  @Test("iOS-04: 自アプリのスキームの standby/start は、要求の ID を添えた待機の開始として読む")
  func startsStandby() throws {
    let url = try #require(
      URL(string: "utterapp://standby/start?request=\(Self.requestID.uuidString)"))

    #expect(
      HostAppLaunchRequest(url: url, scheme: "utterapp")
        == .startStandby(requestID: Self.requestID))
  }

  @Test("iOS-04: スキームと host の大文字・小文字は区別しない")
  func caseInsensitiveSchemeAndHost() throws {
    let url = try #require(
      URL(string: "UtterApp://Standby/start?request=\(Self.requestID.uuidString)"))

    #expect(
      HostAppLaunchRequest(url: url, scheme: "utterapp")
        == .startStandby(requestID: Self.requestID))
  }

  @Test(
    "iOS-03: 本体アプリを開くだけの URL・要求の ID がない URL・別のスキーム・別の操作は何もしない",
    arguments: [
      "utterapp://",
      "utterapp://standby",
      "utterapp://standby/start",
      "utterapp://standby/start?request=not-a-uuid",
      "utterapp://standby/stop?request=6F1C2E8A-3B4D-4E5F-8A9B-0C1D2E3F4A5B",
      "utterapp://standby/start/again?request=6F1C2E8A-3B4D-4E5F-8A9B-0C1D2E3F4A5B",
      "utterapp://record/start?request=6F1C2E8A-3B4D-4E5F-8A9B-0C1D2E3F4A5B",
      "other://standby/start?request=6F1C2E8A-3B4D-4E5F-8A9B-0C1D2E3F4A5B",
      "https://example.com/standby/start?request=6F1C2E8A-3B4D-4E5F-8A9B-0C1D2E3F4A5B",
    ])
  func ignoresOtherURLs(string: String) throws {
    let url = try #require(URL(string: string))

    #expect(HostAppLaunchRequest(url: url, scheme: "utterapp") == nil)
  }

  @Test("iOS-03: スキームを設定していなければ何も読まない", arguments: [nil, "", "  "])
  func ignoresWithoutScheme(scheme: String?) throws {
    let url = try #require(
      URL(string: "utterapp://standby/start?request=\(Self.requestID.uuidString)"))

    #expect(HostAppLaunchRequest(url: url, scheme: scheme) == nil)
  }

  @Test("iOS-04: キーボードが開く URL は、本体アプリが同じ ID の待機の開始として読める")
  func roundTrip() throws {
    let url = try #require(
      HostAppLaunchRequest.startStandbyURL(scheme: "utterapp", requestID: Self.requestID))

    #expect(url.absoluteString == "utterapp://standby/start?request=\(Self.requestID.uuidString)")
    #expect(
      HostAppLaunchRequest(url: url, scheme: "utterapp")
        == .startStandby(requestID: Self.requestID))
  }

  @Test("iOS-03: スキームが空なら、待機を始める URL を作らない")
  func noURLWithoutScheme() {
    #expect(HostAppLaunchRequest.startStandbyURL(scheme: " ", requestID: Self.requestID) == nil)
  }

  // MARK: 開始の要求

  @Test("iOS-04: キーボードが書いた要求は、同じ ID で期限内なら1回だけ消費できる")
  func consumeOnce() async throws {
    let store = StandbySessionStore(directory: directory.url)
    try await store.saveStartRequest(StandbyStartRequest(id: Self.requestID, at: now))

    #expect(await store.consumeStartRequest(Self.requestID, at: now.addingTimeInterval(3)))
    #expect(await !store.consumeStartRequest(Self.requestID, at: now.addingTimeInterval(4)))
  }

  @Test("iOS-04: 要求がなければ、URL を開かれても始めない（他のアプリから開かれたとき）")
  func noRequest() async {
    let store = StandbySessionStore(directory: directory.url)

    #expect(await !store.consumeStartRequest(Self.requestID, at: now))
  }

  @Test("iOS-04: ID が違う要求は始めず、消す（取り違えた要求を後で使わない）")
  func differentID() async throws {
    let store = StandbySessionStore(directory: directory.url)
    try await store.saveStartRequest(StandbyStartRequest(id: Self.requestID, at: now))

    #expect(await !store.consumeStartRequest(UUID(), at: now))
    #expect(await !store.consumeStartRequest(Self.requestID, at: now))
  }

  @Test(
    "iOS-04: 期限を過ぎた要求・時計が大きく先の要求は始めない",
    arguments: [StandbyStartRequest.validity + 1, -(StandbyStartRequest.clockSkewTolerance + 1)])
  func expired(elapsed: TimeInterval) async throws {
    let store = StandbySessionStore(directory: directory.url)
    try await store.saveStartRequest(StandbyStartRequest(id: Self.requestID, at: now))

    #expect(await !store.consumeStartRequest(Self.requestID, at: now.addingTimeInterval(elapsed)))
  }

  @Test("iOS-04: 期限ちょうど・少し先の時刻の要求は受け付ける", arguments: [StandbyStartRequest.validity, -1])
  func withinValidity(elapsed: TimeInterval) async throws {
    let store = StandbySessionStore(directory: directory.url)
    try await store.saveStartRequest(StandbyStartRequest(id: Self.requestID, at: now))

    #expect(await store.consumeStartRequest(Self.requestID, at: now.addingTimeInterval(elapsed)))
  }

  @Test("iOS-04: 要求を消せなければ始めず、残った要求をもう一度使っても始めない")
  func notConsumedWhenRemovalFails() async throws {
    let store = StandbySessionStore(directory: directory.url)
    try await store.saveStartRequest(StandbyStartRequest(id: Self.requestID, at: now))
    let folder = directory.url.path
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder)
    }

    #expect(await !store.consumeStartRequest(Self.requestID, at: now))
    #expect(await !store.consumeStartRequest(Self.requestID, at: now))
  }

  @Test("iOS-04: 壊れた要求では始めない")
  func corrupted() async throws {
    let store = StandbySessionStore(directory: directory.url)
    try await store.saveStartRequest(StandbyStartRequest(id: Self.requestID, at: now))
    try Data("{".utf8).write(to: directory.url.appendingPathComponent("start-request.json"))

    #expect(await !store.consumeStartRequest(Self.requestID, at: now))
  }
}
