import Foundation
import Testing

@testable import UtterPersistence

/// キーボードが本体アプリを開く URL の読み分け（iOS-03・iOS-04, #267）。
struct HostAppLaunchRequestTests {
  @Test("iOS-04: 自アプリのスキームの standby/start は待機を始める")
  func startsStandby() throws {
    let url = try #require(URL(string: "utterapp://standby/start"))

    #expect(HostAppLaunchRequest(url: url, scheme: "utterapp") == .startStandby)
  }

  @Test("iOS-04: スキームと host の大文字・小文字は区別しない")
  func caseInsensitiveSchemeAndHost() throws {
    let url = try #require(URL(string: "UtterApp://Standby/start"))

    #expect(HostAppLaunchRequest(url: url, scheme: "utterapp") == .startStandby)
  }

  @Test(
    "iOS-03: 本体アプリを開くだけの URL・別のスキーム・別の操作は何もしない",
    arguments: [
      "utterapp://",
      "utterapp://standby",
      "utterapp://standby/stop",
      "utterapp://standby/start/again",
      "utterapp://record/start",
      "other://standby/start",
      "https://example.com/standby/start",
    ])
  func ignoresOtherURLs(string: String) throws {
    let url = try #require(URL(string: string))

    #expect(HostAppLaunchRequest(url: url, scheme: "utterapp") == nil)
  }

  @Test("iOS-03: スキームを設定していなければ何も読まない", arguments: [nil, "", "  "])
  func ignoresWithoutScheme(scheme: String?) throws {
    let url = try #require(URL(string: "utterapp://standby/start"))

    #expect(HostAppLaunchRequest(url: url, scheme: scheme) == nil)
  }

  @Test("iOS-04: キーボードが開く URL は、本体アプリが待機を始める URL として読める")
  func roundTrip() throws {
    let url = try #require(HostAppLaunchRequest.startStandbyURL(scheme: "utterapp"))

    #expect(url.absoluteString == "utterapp://standby/start")
    #expect(HostAppLaunchRequest(url: url, scheme: "utterapp") == .startStandby)
  }

  @Test("iOS-03: スキームが空なら、待機を始める URL を作らない")
  func noURLWithoutScheme() {
    #expect(HostAppLaunchRequest.startStandbyURL(scheme: " ") == nil)
  }
}
