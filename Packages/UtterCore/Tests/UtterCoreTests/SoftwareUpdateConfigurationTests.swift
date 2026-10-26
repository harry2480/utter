import Foundation
import Testing

@testable import UtterCore

struct SoftwareUpdateConfigurationTests {
  /// 32 バイトの Base64（ed25519 公開鍵の形。値に意味はない）。
  let validKey = Data(repeating: 7, count: 32).base64EncodedString()
  let feed = "https://example.com/utter/appcast.xml"

  @Test("3章 自動更新: URL も公開鍵もなければ設定を作らない（既定無効）")
  func notConfiguredByDefault() {
    #expect(throws: SoftwareUpdateConfigurationError.notConfigured) {
      try SoftwareUpdateConfiguration(feedURLString: nil, publicEDKey: nil)
    }
    #expect(throws: SoftwareUpdateConfigurationError.notConfigured) {
      try SoftwareUpdateConfiguration(feedURLString: "", publicEDKey: "  \n")
    }
    #expect(throws: SoftwareUpdateConfigurationError.notConfigured) {
      try SoftwareUpdateConfiguration(infoDictionary: [:])
    }
  }

  @Test("3章 自動更新: ビルド設定が空のまま展開された Info.plist では設定を作らない")
  func emptyInfoPlistValuesAreNotConfigured() {
    let info: [String: Any] = [
      "SUFeedURL": "", "SUPublicEDKey": "", "SUScheduledCheckInterval": 604_800,
    ]
    #expect(throws: SoftwareUpdateConfigurationError.notConfigured) {
      try SoftwareUpdateConfiguration(infoDictionary: info)
    }
  }

  @Test("3章 自動更新: 片方だけ与えられたら設定の誤りとして作らない")
  func requiresBothValues() {
    #expect(throws: SoftwareUpdateConfigurationError.missingPublicEDKey) {
      try SoftwareUpdateConfiguration(feedURLString: feed, publicEDKey: "")
    }
    #expect(throws: SoftwareUpdateConfigurationError.missingFeedURL) {
      try SoftwareUpdateConfiguration(feedURLString: nil, publicEDKey: validKey)
    }
  }

  @Test(
    "3章 自動更新: https 以外の URL は受け付けない",
    arguments: [
      "http://example.com/appcast.xml",
      "file:///tmp/appcast.xml",
      "example.com/appcast.xml",
      "https://",
    ])
  func rejectsNonHTTPSFeed(_ url: String) {
    #expect(throws: SoftwareUpdateConfigurationError.feedURLNotHTTPS) {
      try SoftwareUpdateConfiguration(feedURLString: url, publicEDKey: validKey)
    }
  }

  @Test("3章 自動更新: Base64 の 32 バイトでない公開鍵は受け付けない")
  func rejectsInvalidKey() {
    let invalidKeys = [
      "not base64!",
      Data(repeating: 1, count: 31).base64EncodedString(),
      Data(repeating: 1, count: 64).base64EncodedString(),
    ]
    for key in invalidKeys {
      #expect(throws: SoftwareUpdateConfigurationError.invalidPublicEDKey) {
        try SoftwareUpdateConfiguration(feedURLString: feed, publicEDKey: key)
      }
    }
  }

  @Test("3章 自動更新: https の URL と正しい公開鍵がそろえば設定を作る")
  func buildsConfiguration() throws {
    let info: [String: Any] = ["SUFeedURL": " \(feed) ", "SUPublicEDKey": validKey]
    let configuration = try SoftwareUpdateConfiguration(infoDictionary: info)

    #expect(configuration.feedURL == URL(string: feed))
    #expect(configuration.publicEDKey == validKey)
  }

  @Test("3章 自動更新: 文字列でない値は未設定として扱う")
  func nonStringValuesAreIgnored() {
    let info: [String: Any] = ["SUFeedURL": 1, "SUPublicEDKey": true]
    #expect(throws: SoftwareUpdateConfigurationError.notConfigured) {
      try SoftwareUpdateConfiguration(infoDictionary: info)
    }
  }
}
