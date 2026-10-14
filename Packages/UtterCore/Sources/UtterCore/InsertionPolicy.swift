/// アプリごとの挿入の設定（INS-02, INS-05, AC-20）。互換性表の1行に当たる。
public struct AppInsertionProfile: Hashable, Sendable {
  /// 試す経路の順。`nil` なら既定の順を使う
  public var routes: [InsertionRoute]?
  /// ターミナル系のアプリ。Enter を送らず、末尾の改行を挿入しない（INS-03, AC-08）
  public var isTerminal: Bool

  public init(routes: [InsertionRoute]? = nil, isTerminal: Bool = false) {
    self.routes = routes
    self.isTerminal = isTerminal
  }
}

/// 挿入の経路と、次に何をするかを決める（INS-01〜03）。
///
/// 経路の既定の順は Accessibility → Pasteboard → CGEvent で、最後はコピー可能なプレビューに退避する。
/// アプリ別の上書きは互換性表（Phase 0 の結果）をデータとして渡す。
public struct InsertionPolicy: Hashable, Sendable {
  public static let defaultRoutes: [InsertionRoute] = [.accessibility, .pasteboard, .keyEvents]

  public var defaultRoutes: [InsertionRoute]
  /// アプリの識別子（bundle ID など）ごとの設定
  public var profiles: [String: AppInsertionProfile]

  public init(
    defaultRoutes: [InsertionRoute] = InsertionPolicy.defaultRoutes,
    profiles: [String: AppInsertionProfile] = [:]
  ) {
    self.defaultRoutes = defaultRoutes
    self.profiles = profiles
  }

  /// 挿入の計画を立てる。
  ///
  /// - Parameters:
  ///   - app: 前面アプリの識別子。不明なら `nil`
  ///   - recordedTarget: 録音開始時の入力対象
  ///   - currentTarget: 挿入直前の入力対象
  ///   - permittedRoutes: 権限があり使える経路（Pasteboard / CGEvent は許可済みのときだけ含める）
  public func plan(
    app: String?,
    recordedTarget: InsertionTargetID?,
    currentTarget: InsertionTargetID?,
    permittedRoutes: Set<InsertionRoute>
  ) -> InsertionPlan {
    let profile = app.flatMap { profiles[$0] } ?? AppInsertionProfile()
    var seen: Set<InsertionRoute> = []
    let routes = (profile.routes ?? defaultRoutes).filter {
      permittedRoutes.contains($0) && seen.insert($0).inserted
    }
    let reason =
      InsertionTargetID.previewReason(recorded: recordedTarget, current: currentTarget)
      ?? (routes.isEmpty ? .noAvailableRoute : nil)
    return InsertionPlan(routes: routes, isTerminal: profile.isTerminal, previewReason: reason)
  }
}

/// 1回の挿入の計画（INS-01〜03）。
public struct InsertionPlan: Hashable, Sendable {
  /// 試す経路の順
  public let routes: [InsertionRoute]
  /// ターミナル系のアプリ
  public let isTerminal: Bool
  /// 自動挿入せずにプレビューへ退避する理由。自動挿入できるなら `nil`
  public let previewReason: InsertionPreviewReason?

  /// Enter（Return キー）を送ってよいか。ターミナル系では送らない（INS-03, AC-08）
  public var allowsReturnKey: Bool {
    !isTerminal
  }

  /// 挿入する文字列を整える。ターミナル系では末尾の改行を除き、コマンドを実行させない（INS-03, AC-08）。
  public func preparedText(_ text: String) -> String {
    guard isTerminal else { return text }
    var result = Substring(text)
    while let last = result.last, last.isNewline {
      result.removeLast()
    }
    return String(result)
  }

  /// これまでの試行結果から、次に何をするかを決める（INS-02, INS-03）。
  ///
  /// 挿入した可能性がある結果（確認済み・成功不明）が1つでもあれば終える。成功不明でも再試行しない。
  public func nextStep(after attempts: [InsertionResult]) -> InsertionNextStep {
    if let previewReason {
      return .showPreview(previewReason)
    }
    if let inserted = attempts.first(where: \.mayHaveInserted) {
      return .finish(inserted)
    }
    if let preview = attempts.lazy.compactMap(\.previewReason).first {
      return .showPreview(preview)
    }
    let tried = Set(attempts.compactMap(\.route))
    guard let next = routes.first(where: { !tried.contains($0) }) else {
      return .showPreview(.allRoutesFailed)
    }
    return .tryRoute(next)
  }
}

/// 次に行うこと。
public enum InsertionNextStep: Hashable, Sendable {
  /// この経路で挿入を試す
  case tryRoute(InsertionRoute)
  /// 挿入を終える。値は挿入した可能性がある結果（確認済み・成功不明）
  case finish(InsertionResult)
  /// 自動挿入せず、コピー可能なプレビューへ退避する
  case showPreview(InsertionPreviewReason)
}

extension InsertionResult {
  fileprivate var route: InsertionRoute? {
    switch self {
    case .verified(let route), .unconfirmed(let route), .failed(let route): route
    case .preview: nil
    }
  }

  fileprivate var previewReason: InsertionPreviewReason? {
    if case .preview(let reason) = self { reason } else { nil }
  }
}
