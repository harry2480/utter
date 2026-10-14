/// 1回の挿入の計画（INS-01〜03）。
///
/// 呼び出し側は、経路を試す直前ごとに `nextStep(after:currentTarget:)` を呼び、その時点の入力対象を渡す。
/// Enter（Return キー）を自動で送る経路は持たない（INS-03, AC-08）。
public struct InsertionPlan: Hashable, Sendable {
  /// 試す経路の順
  public let routes: [InsertionRoute]
  /// ターミナル系のアプリ
  public let isTerminal: Bool
  public let verification: InsertionTargetVerification

  /// 挿入する文字列を整える。末尾の空白・改行は除く（コマンドを実行させない, INS-03）。
  ///
  /// ターミナル系のアプリで、除いた後も改行を含む場合は `nil` を返す。呼び出し側はプレビューへ退避する
  /// （`InsertionPreviewReason.multilineInTerminal`）。
  public func preparedText(_ text: String) -> String? {
    var result = Substring(text)
    while let last = result.last, last.isWhitespace {
      result.removeLast()
    }
    if isTerminal, result.contains(where: \.isNewline) {
      return nil
    }
    return String(result)
  }

  /// これまでの試行結果と挿入直前の入力対象から、次に何をするかを決める（INS-01〜03）。
  ///
  /// - 挿入した可能性がある結果（確認済み・成功不明）が1つでもあれば終える。成功不明でも再試行しない
  /// - 入力対象が変わった・消えた場合は、次の経路を試さずにプレビューへ退避する
  /// - 計画にない経路の結果は、次に試す経路の選択に使わない
  public func nextStep(
    after attempts: [InsertionResult], currentTarget: InsertionTargetID?
  ) -> InsertionNextStep {
    if let inserted = attempts.first(where: { if case .verified = $0 { true } else { false } })
      ?? attempts.first(where: \.mayHaveInserted)
    {
      return .finish(inserted)
    }
    if let preview = attempts.lazy.compactMap(\.previewReason).first {
      return .showPreview(preview)
    }
    if let reason = verification.previewReason(current: currentTarget) {
      return .showPreview(reason)
    }
    let tried = Set(attempts.compactMap(\.route))
    guard let next = routes.first(where: { !tried.contains($0) }) else {
      return .showPreview(routes.isEmpty ? .noAvailableRoute : .allRoutesFailed)
    }
    return .tryRoute(next)
  }
}

/// 次に行うこと。
public enum InsertionNextStep: Hashable, Sendable {
  /// この経路で挿入を試す
  case tryRoute(InsertionRoute)
  /// 挿入を終える。値は挿入した可能性がある結果（確認済みを優先）
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
