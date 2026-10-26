import Foundation

/// macOS 版の自動更新（Sparkle 2）を起動してよいかの判定と、その設定（3章「自動更新」）。
///
/// Phase 0 #47（依存のライセンス確定）の判定待ちの先行実装で、既定で無効。
/// appcast の URL と EdDSA 公開鍵がどちらもビルド設定で与えられたときだけ設定が作られ、
/// 作れなければ Apps/macOS は Sparkle を起動しない（更新の確認で通信しない）。
/// Info.plist の読み取りと Sparkle の起動は Apps/macOS が行う。
public struct SoftwareUpdateConfiguration: Hashable, Sendable {
  /// appcast の URL を入れる Info.plist のキー（Sparkle の `SUFeedURL`）。
  public static let feedURLKey = "SUFeedURL"
  /// EdDSA（ed25519）公開鍵を入れる Info.plist のキー（Sparkle の `SUPublicEDKey`）。
  public static let publicEDKeyKey = "SUPublicEDKey"

  /// ed25519 公開鍵の長さ（バイト）。
  static let publicKeyByteCount = 32

  /// appcast の URL（https のみ）。
  public let feedURL: URL
  /// EdDSA 公開鍵（Base64）。更新アーカイブの署名の検証に使う。
  public let publicEDKey: String

  /// URL と公開鍵の文字列から設定を作る。前後の空白は無視する。
  ///
  /// どちらも空なら `.notConfigured`（既定の無効状態）。片方だけ・形式が不正なら、
  /// 設定の誤りとして個別のエラーを投げる。いずれの場合も更新機構は作らない。
  public init(feedURLString: String?, publicEDKey: String?) throws(SoftwareUpdateConfigurationError)
  {
    let feed = feedURLString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let key = publicEDKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    switch (feed.isEmpty, key.isEmpty) {
    case (true, true): throw .notConfigured
    case (true, false): throw .missingFeedURL
    case (false, true): throw .missingPublicEDKey
    case (false, false): break
    }

    guard let url = URL(string: feed), url.scheme?.lowercased() == "https", url.host() != nil
    else { throw .feedURLNotHTTPS }
    guard let data = Data(base64Encoded: key), data.count == Self.publicKeyByteCount else {
      throw .invalidPublicEDKey
    }

    self.feedURL = url
    self.publicEDKey = key
  }

  /// Info.plist の内容（`Bundle.infoDictionary`）から設定を作る。文字列でない値は未設定として扱う。
  public init(infoDictionary: [String: Any]) throws(SoftwareUpdateConfigurationError) {
    try self.init(
      feedURLString: infoDictionary[Self.feedURLKey] as? String,
      publicEDKey: infoDictionary[Self.publicEDKeyKey] as? String)
  }
}

/// 自動更新の設定を作れなかった理由。`.notConfigured` 以外は設定の誤り。
public enum SoftwareUpdateConfigurationError: Error, Hashable, Sendable {
  /// URL も公開鍵も与えられていない（既定の無効状態）。
  case notConfigured
  /// 公開鍵だけがあり、appcast の URL がない。
  case missingFeedURL
  /// appcast の URL だけがあり、公開鍵がない。
  case missingPublicEDKey
  /// appcast の URL が https の URL として読めない。
  case feedURLNotHTTPS
  /// 公開鍵が Base64 の 32 バイト（ed25519）でない。
  case invalidPublicEDKey
}
