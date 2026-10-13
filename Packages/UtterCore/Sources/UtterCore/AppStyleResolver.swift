/// 前面アプリの bundle ID から整形スタイルを選ぶ（CTX-01, CTX-02）。
///
/// 利用者のアプリ別上書き、既定の対応表、`standard` の順に判定する。
/// 判定結果はスタイル区分だけで、bundle ID はクラウドへ送る入力に含めない（CTX-03）。
/// bundle ID は大文字・小文字を区別せずに照合する。
public struct AppStyleResolver: Hashable, Sendable {
  /// 既定の対応表（CTX-01）。キーは小文字に正規化した bundle ID。
  public let defaultStyles: [String: RefinementStyle]
  /// 利用者のアプリ別上書き（CTX-02）。キーは小文字に正規化した bundle ID。
  public private(set) var overrides: [String: RefinementStyle]

  /// - Parameters:
  ///   - defaultStyles: 既定の対応表。省略時は `AppStyleResolver.builtInStyles`
  ///   - overrides: 利用者のアプリ別上書き
  public init(
    defaultStyles: [String: RefinementStyle] = AppStyleResolver.builtInStyles,
    overrides: [String: RefinementStyle] = [:]
  ) {
    self.defaultStyles = Self.normalizedKeys(defaultStyles)
    self.overrides = Self.normalizedKeys(overrides)
  }

  /// 前面アプリのスタイルを返す。前面アプリを特定できない（`nil` または空文字）・未知のアプリは `standard`。
  public func style(forBundleID bundleID: String?) -> RefinementStyle {
    guard let bundleID, !bundleID.isEmpty else { return .standard }
    let key = Self.normalized(bundleID)
    return overrides[key] ?? defaultStyles[key] ?? .standard
  }

  /// アプリ別の上書きを設定する（CTX-02）。`nil` を渡すと上書きを外し、既定の対応表に戻す。
  /// 空文字の bundle ID は無視する。
  public mutating func setOverride(_ style: RefinementStyle?, forBundleID bundleID: String) {
    guard !bundleID.isEmpty else { return }
    overrides[Self.normalized(bundleID)] = style
  }

  private static func normalized(_ bundleID: String) -> String {
    bundleID.lowercased()
  }

  /// 大文字・小文字だけが異なるキーが重なった場合は、Unicode スカラー順で先のキー（大文字を含む方）の値を採る。
  /// 空文字のキーは除く。
  private static func normalizedKeys(
    _ styles: [String: RefinementStyle]
  ) -> [String: RefinementStyle] {
    var result: [String: RefinementStyle] = [:]
    for key in styles.keys.sorted() where !key.isEmpty {
      let normalizedKey = normalized(key)
      if result[normalizedKey] == nil {
        result[normalizedKey] = styles[key]
      }
    }
    return result
  }
}

extension AppStyleResolver {
  /// 既定の対応表の元データ（CTX-01）。スタイルごとに bundle ID を並べる。
  static let builtInGroups: [(style: RefinementStyle, bundleIDs: [String])] = [
    // チャット
    (
      .concise,
      [
        "com.hnc.Discord",
        "com.tinyspeck.slackmacgap",
        "com.microsoft.teams2",
        "com.apple.MobileSMS",
        "jp.naver.line.mac",
      ]
    ),
    // メール
    (
      .polite,
      [
        "com.apple.mail",
        "com.microsoft.Outlook",
        "com.readdle.smartemail-Mac",  // Spark Classic
        "com.readdle.SparkDesktop",
        "org.mozilla.thunderbird",
      ]
    ),
    // IDE・コードエディター
    (
      .technical,
      [
        "com.apple.dt.Xcode",
        "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92",  // Cursor
        "dev.zed.Zed",
        "com.sublimetext.4",
        "com.google.android.studio",
        "com.jetbrains.intellij",
        "com.jetbrains.intellij.ce",
        "com.jetbrains.pycharm",
        "com.jetbrains.pycharm.ce",
        "com.jetbrains.WebStorm",
        "com.jetbrains.goland",
      ]
    ),
    // ターミナル
    (
      .command,
      [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty",
        "org.alacritty",
        "com.github.wez.wezterm",
      ]
    ),
    // 文書アプリ
    (
      .document,
      [
        "com.apple.iWork.Pages",
        "com.microsoft.Word",
        "com.apple.TextEdit",
        "com.apple.Notes",
        "md.obsidian",
        "notion.id",
      ]
    ),
  ]

  /// 既定の対応表（CTX-01）。
  public static let builtInStyles: [String: RefinementStyle] = Dictionary(
    builtInGroups.flatMap { group in group.bundleIDs.map { ($0, group.style) } },
    uniquingKeysWith: { first, _ in first }
  )
}
