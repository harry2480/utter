import Foundation

/// キーボードが本体アプリを開くときの URL が求めること（iOS-03・iOS-04）。
///
/// 本体アプリが登録した自アプリの URL スキームだけを読む。`<scheme>://standby/start` は、キーボードのマイクの操作で
/// 待機を始めることを求める。それ以外（`<scheme>://` を含む）は、本体アプリを開くだけで何もしない。
/// URL は誰でも開けるため、ここで始めるのは待機だけにする（待機中もマイクは合図までミュートで、録音はキーボードの合図でだけ始まる）。
public enum HostAppLaunchRequest: Equatable, Sendable {
  /// 待機を始める
  case startStandby

  static let standbyHost = "standby"
  static let startPath = "/start"

  /// - Parameters:
  ///   - url: 開かれた URL
  ///   - scheme: 本体アプリが登録した URL スキーム。未設定（空）なら何も読まない
  public init?(url: URL, scheme: String?) {
    guard let scheme = scheme?.trimmingCharacters(in: .whitespaces), !scheme.isEmpty,
      url.scheme?.lowercased() == scheme.lowercased(),
      url.host()?.lowercased() == Self.standbyHost,
      url.path() == Self.startPath
    else {
      return nil
    }
    self = .startStandby
  }

  /// キーボードが開く、待機を始める URL。スキームが空・URL にできなければ `nil`
  public static func startStandbyURL(scheme: String) -> URL? {
    let scheme = scheme.trimmingCharacters(in: .whitespaces)
    guard !scheme.isEmpty else { return nil }
    return URL(string: "\(scheme)://\(standbyHost)\(startPath)")
  }
}
