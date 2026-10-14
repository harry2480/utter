/// 1つの経路で挿入を試した結果（INS-03, INS-05）。
public enum InsertionResult: Hashable, Sendable {
  /// 挿入後の値を読み戻して確認できた
  case verified(InsertionRoute)
  /// 入った可能性があるが確認できない。二重挿入を避けるため再試行しない
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

/// 経路の応答（INS-05）。
public enum InsertionResponse: Hashable, Sendable {
  /// 成功を返した
  case succeeded
  /// 送信する前に失敗した（入力要素がない、権限がないなど）。何も送っていない
  case rejectedBeforeSend
  /// 送信した後に失敗を返した。一部または全部が入った可能性がある
  case failedAfterSend
}

/// 挿入後の値を読み戻した結果（INS-05）。
///
/// アダプターは、アプリが値を反映するのを待ってから読み戻す。早すぎる読み戻しで `unchanged` にしない。
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
  /// 経路の応答と読み戻しの結果から、挿入結果を決める（INS-05）。
  ///
  /// 成功応答だけでは信用せず、読み戻しで一致した場合だけ確認済みとする。
  /// 次の経路を試してよい「失敗」は、送信前の失敗か、読み戻しで変化がないと確かめられた場合に限る。
  public static func classify(
    route: InsertionRoute, response: InsertionResponse, readBack: InsertionReadBack
  ) -> InsertionResult {
    switch (readBack, response) {
    case (.matches, _):
      .verified(route)
    case (.differs, _):
      .unconfirmed(route)
    case (.unchanged, _), (.unavailable, .rejectedBeforeSend):
      .failed(route)
    case (.unavailable, .succeeded), (.unavailable, .failedAfterSend):
      .unconfirmed(route)
    }
  }
}
