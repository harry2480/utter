import UtterAI
import UtterCore
import UtterText

// Edit Mode（AC-14, v1.1）で使う OS の機能と画面の境界。本番は AX のアダプターとパネル、テストは Stub を渡す。
// 選択テキスト・音声指示・編集案は、どれも記録・ログ出力しない。

/// 入力欄の選択範囲の読み取りと置き換え（Accessibility）。
///
/// 値と選択範囲の読み取り・`kAXSelectedTextAttribute` への書き込みは `InsertionFieldAccess` のものを使う。
@MainActor
protocol EditFieldAccess: InsertionFieldAccess {
  /// 選択中のテキスト（`kAXSelectedTextAttribute`）。読めなければ `nil`
  func selectedText(of target: InsertionTargetID) -> String?
  /// 選択範囲を変える（`kAXSelectedTextRangeAttribute`, UTF-16 単位）。変えられたら `true`
  func select(_ range: FieldSnapshot.Selection, in target: InsertionTargetID) -> Bool
  /// 入力欄がセキュア属性（パスワード欄）か。要素が見つからなければ判定できない（`.unknown`）
  func secureField(of target: InsertionTargetID) -> SensitiveSignal
}

/// Edit Mode の差分プレビュー・通知・退避を表示する。
@MainActor
protocol EditModePresenting: AnyObject {
  /// 編集案の差分を表示し、確定かキャンセルを待つ。前の編集案があれば置き換える
  func showProposal(_ proposal: EditProposal)
  /// 差分プレビューを閉じる
  func dismissProposal()
  /// 結果を通知する。本文は含めない
  func showNotice(_ notice: EditModeNotice)
  /// 自動で置き換え・復元できなかった文字列を、コピーできるパネルで表示する（AC-09 と同じ退避）
  func showFallback(text: String, cause: EditFallbackCause)
}

/// Edit を始められなかった理由。
enum EditStartFailure: Hashable, Sendable {
  /// Accessibility が未許可で、選択範囲を読めない（PERM-02）
  case accessibilityNotTrusted
  /// フォーカス中の入力欄が見つからない
  case targetMissing
  /// パスワード欄・セキュア入力・機密アプリ・除外アプリ、または判定できない（7章）
  case sensitiveInput(Set<SensitiveInputReason>)
  /// 選択されたテキストがない
  case noSelection
  /// 値・選択範囲を読めない、または食い違っていて、置き換えと復元を確かめられない
  case selectionUnreadable
}

/// 自動で置き換え・復元せず、文字列を退避した理由。
enum EditFallbackCause: Error, Hashable, Sendable {
  /// Accessibility が未許可になった（PERM-02）
  case accessibilityNotTrusted
  /// 入力欄が見つからない・値を読めない
  case targetMissing
  /// パスワード欄・セキュア入力・機密アプリ・除外アプリ、または判定できない（7章）
  case sensitiveInput(Set<SensitiveInputReason>)
  /// 確認中に選択範囲の文字列が変わった。利用者の入力を上書きしないよう置き換えない
  case selectionChanged
  /// 選択範囲が動いていて、元の範囲を選び直せなかった。別の位置へ書き込まないよう置き換えない
  case cannotReselect
  /// 書き込みを拒否された、または読み戻しで変化がないと確かめた
  case replacementFailed
  /// 確定後に該当範囲が書き換えられていた。利用者の入力を上書きしないよう元に戻さない
  case changedSinceCommit
}

/// Edit Mode の通知。本文は含めない。
enum EditModeNotice: Hashable, Sendable {
  case couldNotStart(EditStartFailure)
  /// 編集案を得られなかった。選択範囲は変えていない
  case notEdited(EditFailureReason)
  /// 置き換えた。`verified` が `false` なら読み戻しで確かめられていない（成功不明, INS-05）
  case replaced(verified: Bool)
  /// 元に戻した。`verified` が `false` なら読み戻しで確かめられていない
  case restored(verified: Bool)
  /// アプリの取り消し（⌘Z）などで、すでに元のテキストに戻っていた
  case alreadyRestored
}
