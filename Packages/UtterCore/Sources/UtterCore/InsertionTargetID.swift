/// 入力対象（アプリの入力欄）を抽象化した識別子（INS-01）。
///
/// アプリ側が AX 要素などを不透明な値に対応づけて作る。同一性の比較だけに使い、
/// 入力欄の内容やウィンドウタイトルを含めない。文字列表現には値を出さない。
public struct InsertionTargetID: Hashable, Sendable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }
}

extension InsertionTargetID: CustomStringConvertible, CustomReflectable {
  public var description: String {
    "InsertionTargetID(length: \(rawValue.count))"
  }

  public var customMirror: Mirror {
    Mirror(self, children: ["length": rawValue.count])
  }
}

/// 挿入先の確かめ方（INS-01, iOS-06）。
public enum InsertionTargetVerification: Hashable, Sendable {
  /// 録音開始時に記録した入力対象と、挿入直前の入力対象を比べる（macOS）
  case compare(recorded: InsertionTargetID?)
  /// 公開 API で同一性を確かめられないため、利用者が挿入先を確認した（iOS-06）。同一性は保証しない
  case confirmedByUser
}

/// 自動挿入せず、コピー可能なプレビューへ退避する理由（INS-01, INS-02, INS-03, AC-09）。
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
  /// ターミナル系のアプリへ改行を含む文字列を挿入しようとした。改行が Enter として実行されるため自動挿入しない
  case multilineInTerminal
}

extension InsertionTargetVerification {
  /// 挿入直前の入力対象で、自動挿入できなければ退避の理由を返す（INS-01）。
  public func previewReason(current: InsertionTargetID?) -> InsertionPreviewReason? {
    switch self {
    case .confirmedByUser:
      return nil
    case .compare(let recorded):
      guard let recorded else { return .targetUnknown }
      guard let current else { return .targetMissing }
      return recorded == current ? nil : .targetChanged
    }
  }
}
