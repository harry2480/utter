/// アプリごとの挿入の設定（INS-02, INS-05, AC-20）。互換性表の1行に当たる。
public struct AppInsertionProfile: Hashable, Sendable {
  /// 試す経路の順。`nil` なら既定の順を使う
  public var routes: [InsertionRoute]?
  /// ターミナル系のアプリ。改行を含む文字列は自動挿入しない（INS-03, AC-08）
  ///
  /// 整形スタイル（`command`）とは別に持つ。スタイルは利用者が上書きできるため（CTX-02）、
  /// 上書きで安全装置が外れないようにする。
  public var isTerminal: Bool

  public init(routes: [InsertionRoute]? = nil, isTerminal: Bool = false) {
    self.routes = routes
    self.isTerminal = isTerminal
  }
}

/// 挿入の経路と、次に何をするかを決める（INS-01〜03）。
///
/// 経路の既定の順は Accessibility → Pasteboard → CGEvent で、最後はコピー可能なプレビューに退避する。
/// アプリ別の上書きは互換性表（Phase 0 の結果）をデータとして渡す。アプリの識別子は大文字・小文字を区別しない。
public struct InsertionPolicy: Hashable, Sendable {
  public static let defaultRoutes: [InsertionRoute] = [.accessibility, .pasteboard, .keyEvents]

  public let defaultRoutes: [InsertionRoute]
  /// アプリの識別子（bundle ID など、小文字に正規化したもの）ごとの設定
  public let profiles: [String: AppInsertionProfile]

  public init(
    defaultRoutes: [InsertionRoute] = InsertionPolicy.defaultRoutes,
    profiles: [String: AppInsertionProfile] = [:]
  ) {
    self.defaultRoutes = defaultRoutes
    self.profiles = Dictionary(
      profiles.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
  }

  public func profile(for app: String?) -> AppInsertionProfile {
    app.flatMap { profiles[$0.lowercased()] } ?? AppInsertionProfile()
  }

  /// 挿入の計画を立てる。
  ///
  /// - Parameters:
  ///   - app: 前面アプリの識別子。不明なら `nil`
  ///   - verification: 挿入先の確かめ方
  ///   - permittedRoutes: 権限があり使える経路（Pasteboard / CGEvent は許可済みのときだけ含める）
  public func plan(
    app: String?,
    verification: InsertionTargetVerification,
    permittedRoutes: Set<InsertionRoute>
  ) -> InsertionPlan {
    let profile = profile(for: app)
    var seen: Set<InsertionRoute> = []
    let routes = (profile.routes ?? defaultRoutes).filter {
      permittedRoutes.contains($0) && seen.insert($0).inserted
    }
    return InsertionPlan(routes: routes, isTerminal: profile.isTerminal, verification: verification)
  }
}
