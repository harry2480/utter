/// 1つの経路で挿入を試した結果（INS-03, INS-05）。
public enum InsertionResult: Hashable, Sendable {
  /// 挿入後の値を読み戻して確認できた
  case verified(InsertionRoute)
  /// 成功応答はあったが確認できない。二重挿入を避けるため再試行しない
  case unconfirmed(InsertionRoute)
  /// 挿入されていないことが確かな失敗。次の経路を試してよい
  case failed(InsertionRoute)
  /// 自動挿入せず、コピー可能なプレビューへ退避した
  case preview(InsertionPreviewReason)

  /// 挿入した可能性があるか。`true` なら同じ内容を別の経路で再び挿入しない
  public var mayHaveInserted: Bool {
    switch self {
    case .verified, .unconfirmed: true
    case .failed, .preview: false
    }
  }
}

/// 挿入後の値を読み戻した結果（INS-05）。
public enum InsertionReadBack: Hashable, Sendable {
  /// 挿入した文字列が期待どおりの位置にある
  case matches
  /// 挿入前と変わっていない
  case unchanged
  /// 挿入前と変わったが、期待どおりではない（一部だけ入った可能性がある）
  case differs
  /// このアプリでは読み戻せない
  case unavailable
}

extension InsertionResult {
  /// 経路の成功応答と読み戻しの結果から、挿入結果を決める（INS-05）。
  ///
  /// 成功応答だけでは信用せず、読み戻しで一致した場合だけ確認済みとする。
  /// 失敗応答でも読み戻しで変化があれば、入った可能性があるため成功不明とする。
  public static func classify(
    route: InsertionRoute, reportedSuccess: Bool, readBack: InsertionReadBack
  ) -> InsertionResult {
    switch readBack {
    case .matches:
      .verified(route)
    case .unchanged:
      .failed(route)
    case .differs:
      .unconfirmed(route)
    case .unavailable:
      reportedSuccess ? .unconfirmed(route) : .failed(route)
    }
  }
}
