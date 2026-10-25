/// Web サイト単位のスタイル上書きと、その利用の許可（CTX-02）。
///
/// サイト単位の識別は明示的な許可制で、許可（`isSiteIdentificationAllowed`）の既定は無効。
/// 許可がなければ、ホスト名を受け取っても判定に使わない。上書きの一覧は許可の有無にかかわらず保持し、
/// 許可を外しても消さない（再び許可したときに使う）。
///
/// ブラウザから URL を取り出す処理（AX など）は Apps/macOS の責務で、取り出す前に `needsSiteHost` を確かめる。
/// 判定結果はスタイル区分だけで、ホスト名と URL はクラウドへ送る入力に含めない（CTX-03）。
public struct SiteStyleResolver: Hashable, Sendable {
  /// サイト単位の識別を許可しているか。既定は無効
  public var isSiteIdentificationAllowed: Bool
  /// 利用者のサイト別上書き
  public private(set) var overrides: [SiteHost: RefinementStyle]

  /// - Parameters:
  ///   - isSiteIdentificationAllowed: サイト単位の識別を許可するか。既定は無効
  ///   - overrides: サイト別の上書き。キーは `SiteHost(host:)` で正規化し、正規化できないキーは除く。
  ///     正規化後に重なるキーは、Unicode スカラー順で先のキーの値を採る（`AppStyleResolver.normalizedKeys` と同じ）
  public init(
    isSiteIdentificationAllowed: Bool = false,
    overrides: [String: RefinementStyle] = [:]
  ) {
    self.isSiteIdentificationAllowed = isSiteIdentificationAllowed
    var normalized: [SiteHost: RefinementStyle] = [:]
    for key in overrides.keys.sorted() {
      guard let host = SiteHost(host: key), normalized[host] == nil else { continue }
      normalized[host] = overrides[key]
    }
    self.overrides = normalized
  }

  /// 前面のブラウザから表示中のホスト名を取り出す必要があるか。
  /// 許可がない、または上書きが1件もない場合は `false` で、Apps/macOS は URL を読みに行かない。
  public var needsSiteHost: Bool {
    isSiteIdentificationAllowed && !overrides.isEmpty
  }

  /// サイト別の上書きを返す。許可がない・ホスト名がない・上書きがない場合は `nil`。
  public func style(forSiteHost host: SiteHost?) -> RefinementStyle? {
    guard isSiteIdentificationAllowed, let host else { return nil }
    return overrides[host]
  }

  /// サイト別の上書きを設定する（CTX-02）。`nil` を渡すと上書きを外す。
  public mutating func setOverride(_ style: RefinementStyle?, forSiteHost host: SiteHost) {
    overrides[host] = style
  }
}

// ホスト名をログに出さないよう、文字列表現とリフレクションには件数だけを出す（CTX-03）。
extension SiteStyleResolver: CustomStringConvertible, CustomDebugStringConvertible,
  CustomReflectable
{
  public var description: String {
    "SiteStyleResolver(isSiteIdentificationAllowed: \(isSiteIdentificationAllowed), overrides: \(overrides.count))"
  }

  public var debugDescription: String { description }

  public var customMirror: Mirror {
    Mirror(
      self,
      children: [
        "isSiteIdentificationAllowed": isSiteIdentificationAllowed,
        "overrides": overrides.count,
      ]
    )
  }
}

/// 前面アプリとサイトから整形スタイルを選ぶ（CTX-01, CTX-02）。
///
/// 優先順位は、サイト別の上書き（許可がある場合だけ）→ アプリ別の上書き → 既定の対応表 → `standard`。
/// サイトはアプリ（ブラウザ）より範囲が狭く、利用者が明示的に設定したものなので最優先にする。
/// サイト別の既定の対応表は持たない（サイトは利用者の上書きだけで判定する）。
public struct ContextStyleResolver: Hashable, Sendable {
  public var app: AppStyleResolver
  public var site: SiteStyleResolver

  public init(
    app: AppStyleResolver = AppStyleResolver(), site: SiteStyleResolver = SiteStyleResolver()
  ) {
    self.app = app
    self.site = site
  }

  /// 前面アプリと表示中のサイトのスタイルを返す。
  /// - Parameters:
  ///   - bundleID: 前面アプリの bundle ID。特定できなければ `nil`
  ///   - siteHost: 前面のブラウザで表示中のホスト名。ブラウザでない・取り出せない・許可がない場合は `nil`
  public func style(forBundleID bundleID: String?, siteHost: SiteHost? = nil) -> RefinementStyle {
    site.style(forSiteHost: siteHost) ?? app.style(forBundleID: bundleID)
  }
}

// bundle ID の上書きは利用状況を表し、サイトの上書きは閲覧先を表すため、件数だけを出す（CTX-03）。
extension ContextStyleResolver: CustomStringConvertible, CustomDebugStringConvertible,
  CustomReflectable
{
  public var description: String {
    "ContextStyleResolver(appOverrides: \(app.overrides.count), site: \(site))"
  }

  public var debugDescription: String { description }

  public var customMirror: Mirror {
    Mirror(self, children: ["appOverrides": app.overrides.count, "site": site])
  }
}
