import Foundation
import Testing

@testable import UtteriOSKit

/// 個人署名の期限の読み取りと残り日数（要件定義 12.6節, #200）。
struct SigningExpiryTests {
  private static let expiration = Date(timeIntervalSince1970: 1_800_000_000)

  /// CMS の署名の前後のバイト列で plist を挟んだ、`embedded.mobileprovision` に似た中身
  private static func mobileProvision(_ plist: [String: Any]) throws -> Data {
    let xml = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    return Data([0x30, 0x82, 0x0F, 0x00, 0x06, 0x09]) + xml + Data([0xA0, 0x82, 0x00, 0x3C, 0x30])
  }

  @Test("12.6節: embedded.mobileprovision の ExpirationDate を期限として読む")
  func readsExpirationDate() throws {
    let data = try Self.mobileProvision(["Name": "Team", "ExpirationDate": Self.expiration])

    #expect(SigningExpiry(mobileProvision: data)?.expirationDate == Self.expiration)
  }

  @Test(
    "12.6節: plist がない・期限がない・壊れた中身なら読めないものとして警告を出さない",
    arguments: [
      Data(),
      Data([0x30, 0x82, 0x00, 0x01]),
      Data("<?xml version=\"1.0\"?><plist><dict>".utf8),
      Data("<?xml version=\"1.0\"?><plist>broken</plist>".utf8),
    ])
  func unreadable(data: Data) {
    #expect(SigningExpiry(mobileProvision: data) == nil)
  }

  @Test("12.6節: ExpirationDate がない plist は読めない")
  func missingExpirationDate() throws {
    let data = try Self.mobileProvision(["Name": "Team"])

    #expect(SigningExpiry(mobileProvision: data) == nil)
  }

  @Test(
    "12.6節: 残り日数は切り捨てて出し、2日を下回ったら警告する",
    arguments: [
      (7.0 * 86_400, SigningExpiryStatus.remaining(days: 7), false),
      (6.9 * 86_400, .remaining(days: 6), false),
      (2.0 * 86_400, .remaining(days: 2), false),
      (1.5 * 86_400, .remaining(days: 1), true),
      (3_600, .lessThanOneDay, true),
      (0, .expired, true),
      (-86_400, .expired, true),
    ] as [(TimeInterval, SigningExpiryStatus, Bool)])
  func status(remaining: TimeInterval, expected: SigningExpiryStatus, isWarning: Bool) {
    let expiry = SigningExpiry(expirationDate: Self.expiration)

    let status = expiry.status(at: Self.expiration.addingTimeInterval(-remaining))

    #expect(status == expected)
    #expect(status.isWarning == isWarning)
  }

  @Test("12.6節: 残り日数と、期限が近い・過ぎたときの入れ直しを文言に出す")
  func messages() {
    #expect(SigningExpiryStatus.remaining(days: 5).message.contains("あと 5 日"))
    #expect(SigningExpiryStatus.lessThanOneDay.message.contains("もう一度インストール"))
    #expect(SigningExpiryStatus.expired.message.contains("過ぎました"))
  }
}
