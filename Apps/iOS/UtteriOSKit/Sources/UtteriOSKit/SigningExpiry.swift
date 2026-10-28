import Foundation

/// 個人署名（プロビジョニングプロファイル）の期限と、残り日数の表示（要件定義 12.6節, iAC-07, #200）。
///
/// 無料の Personal Team ではプロファイルの有効期間が通常7日で、過ぎるとアプリを開けなくなる。
/// 期限はアプリに埋め込まれた `embedded.mobileprovision`（CMS で署名された plist）の `ExpirationDate` から読む。
/// 署名部分は検証せず、XML の plist の部分（`<?xml` から `</plist>` まで）だけを取り出して読む（非公開 API は使わない）。
/// App Store・TestFlight のビルドやシミュレータにはファイルがなく、読めなければ警告を出さない。
public struct SigningExpiry: Hashable, Sendable {
  /// 残りがこの日数を下回ったら、ホームでも警告する
  public static let warningThresholdDays = 2

  public let expirationDate: Date

  public init(expirationDate: Date) {
    self.expirationDate = expirationDate
  }

  /// `embedded.mobileprovision` の中身から期限を読む。読めなければ `nil`
  public init?(mobileProvision data: Data) {
    guard let start = data.range(of: Data("<?xml".utf8)),
      let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex)
    else {
      return nil
    }
    let plist = data.subdata(in: start.lowerBound..<end.upperBound)
    guard
      let dictionary = try? PropertyListSerialization.propertyList(
        from: plist, options: [], format: nil) as? [String: Any],
      let expirationDate = dictionary["ExpirationDate"] as? Date
    else {
      return nil
    }
    self.init(expirationDate: expirationDate)
  }

  /// `now` の時点での残り
  public func status(at now: Date) -> SigningExpiryStatus {
    let remaining = expirationDate.timeIntervalSince(now)
    guard remaining > 0 else { return .expired }
    // 切り捨てる（6日と20時間なら「あと6日」）。期限の当日に開けなくなるのを避けるため、少なめに出す
    let days = Int(remaining / 86_400)
    return days == 0 ? .lessThanOneDay : .remaining(days: days)
  }
}

/// 個人署名の残り。
public enum SigningExpiryStatus: Hashable, Sendable {
  /// 残り `days` 日（1日以上）
  case remaining(days: Int)
  /// 1日を切った
  case lessThanOneDay
  /// 期限を過ぎた（次に起動できなくなる）
  case expired

  /// ホームでも警告するか。残りが `SigningExpiry.warningThresholdDays` 日を下回ったら
  public var isWarning: Bool {
    switch self {
    case .remaining(let days): days < SigningExpiry.warningThresholdDays
    case .lessThanOneDay, .expired: true
    }
  }

  /// 画面に出す文言
  public var message: String {
    switch self {
    case .remaining(let days):
      "署名の期限まで、あと \(days) 日です。"
    case .lessThanOneDay:
      "署名の期限まで1日を切りました。Xcode からもう一度インストールしてください。"
    case .expired:
      "署名の期限を過ぎました。Xcode からもう一度インストールしてください。"
    }
  }
}
