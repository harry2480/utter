import Foundation

/// キーボードが本体アプリを開くときの URL が求めること（iOS-03・iOS-04）。
///
/// 本体アプリが登録した自アプリの URL スキームだけを読む。`<scheme>://standby/start?request=<ID>` は、キーボードのマイクの操作で
/// 待機を始めることを求める。それ以外（`<scheme>://` を含む）は、本体アプリを開くだけで何もしない。
/// URL は他のアプリからも開けるため、URL だけでは待機を始めない。キーボードが App Group に書いた同じ ID の
/// 開始の要求（`StandbyStartRequest`）を本体アプリが消費できたときだけ始める（`StandbySessionStore.consumeStartRequest`）。
public enum HostAppLaunchRequest: Equatable, Sendable {
  /// 待機を始める。`requestID` はキーボードが App Group に書いた開始の要求の ID
  case startStandby(requestID: UUID)

  static let standbyHost = "standby"
  static let startPath = "/start"
  static let requestQueryName = "request"

  /// - Parameters:
  ///   - url: 開かれた URL
  ///   - scheme: 本体アプリが登録した URL スキーム。未設定（空）なら何も読まない
  public init?(url: URL, scheme: String?) {
    guard let scheme = scheme?.trimmingCharacters(in: .whitespaces), !scheme.isEmpty,
      url.scheme?.lowercased() == scheme.lowercased(),
      url.host()?.lowercased() == Self.standbyHost,
      url.path() == Self.startPath,
      let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
      let value = items.first(where: { $0.name == Self.requestQueryName })?.value,
      let requestID = UUID(uuidString: value)
    else {
      return nil
    }
    self = .startStandby(requestID: requestID)
  }

  /// キーボードが開く、待機を始める URL。スキームが空・URL にできなければ `nil`
  public static func startStandbyURL(scheme: String, requestID: UUID) -> URL? {
    let scheme = scheme.trimmingCharacters(in: .whitespaces)
    guard !scheme.isEmpty else { return nil }
    var components = URLComponents()
    components.scheme = scheme
    components.host = standbyHost
    components.path = startPath
    components.queryItems = [URLQueryItem(name: requestQueryName, value: requestID.uuidString)]
    return components.url
  }
}

/// キーボードのマイクの操作で、本体アプリに待機を始めてもらう要求（iOS-04, #267）。
///
/// キーボードが App Group に書いてから本体アプリを開き、本体アプリが URL の ID と照らして1回だけ消費する。
/// 他のアプリは App Group を読み書きできないため、URL を開かれても要求がなければ待機は始まらない。
public struct StandbyStartRequest: Hashable, Sendable, Codable {
  public let id: UUID
  public let at: Date

  /// 書いてから本体アプリが受け取るまでに待つ長さ。開く操作とアプリの起動に足りる長さにとどめる
  public static let validity: TimeInterval = 30
  /// 端末の時計のずれを許す長さ（書いた時刻が少し先でも受け付ける）
  static let clockSkewTolerance: TimeInterval = 5

  public init(id: UUID = UUID(), at: Date) {
    self.id = id
    self.at = at
  }

  /// `now` の時点で、`requestID` の要求として有効か
  func accepts(_ requestID: UUID, at now: Date) -> Bool {
    let elapsed = now.timeIntervalSince(at)
    return id == requestID && elapsed >= -Self.clockSkewTolerance && elapsed <= Self.validity
  }
}
