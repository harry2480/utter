import UtterCore
import UtterText

/// Realtime Direct の入力欄の読み書き（Accessibility, 2.2節, AC-15）。
///
/// 値・選択範囲の読み取りは挿入と同じ `snapshot(of:)` を使い、指定した範囲だけを置き換える操作を足す。
/// 本番は `AccessibilityInsertionTarget`、テストは Stub。入力欄の値は照合にだけ使い、記録・表示しない。
@MainActor
protocol RealtimeDirectFieldAccess: InsertionFieldAccess {
  /// `range`（UTF-16）を選択して `replacement` に置き換え、カーソルを `caretLocation` に置く。
  ///
  /// 選択範囲の設定に失敗したら何も書き込まずに `rejectedBeforeSend` を返す。書き込んだ後のカーソルの設定に
  /// 失敗した場合も、範囲を確かめられないため `failedAfterSend` を返す。
  func replace(
    _ range: UTF16TextRange, with replacement: String, caretLocation: Int,
    in target: InsertionTargetID
  ) -> InsertionResponse
}
