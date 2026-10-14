/// 入力対象（アプリの入力欄）を抽象化した識別子（INS-01）。
///
/// アプリ側が AX 要素などから作る。値は同一性の比較だけに使い、入力欄の内容やウィンドウタイトルを含めない。
public struct InsertionTargetID: Hashable, Sendable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }
}

/// 自動挿入せず、コピー可能なプレビューへ退避する理由（INS-01, INS-02, AC-09）。
public enum InsertionPreviewReason: Hashable, Sendable {
  /// 録音開始時に入力対象を記録できなかった
  case targetUnknown
  /// 挿入直前に入力対象が見つからない
  case targetMissing
  /// 挿入直前の入力対象が録音開始時と別の要素になっている
  case targetChanged
  /// 使える経路がすべて失敗した
  case allRoutesFailed
  /// 使える経路がない（権限がないなど）
  case noAvailableRoute
}

extension InsertionTargetID {
  /// 録音開始時と挿入直前の入力対象を比べ、自動挿入できなければ退避の理由を返す（INS-01）。
  public static func previewReason(
    recorded: InsertionTargetID?, current: InsertionTargetID?
  ) -> InsertionPreviewReason? {
    guard let recorded else { return .targetUnknown }
    guard let current else { return .targetMissing }
    return recorded == current ? nil : .targetChanged
  }
}
