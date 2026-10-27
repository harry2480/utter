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

/// 選択テキストと音声指示の送信（AC-14, AC-06, AI-04, AI-05）。
///
/// 本番は `EditModeRequestPipeline`（設定・同意・API キー・予算を送るたびに読み直し、`EditRouter` で Claude へ送る）。
/// テストは `EditRouter` と Stub のプロバイダーを包んだ `RouterEditSender` を使う。
@MainActor
protocol EditRequestSending: AnyObject {
  /// 選択テキストの送信先。送信の前に、この送信先への選択テキストの送信の同意（`editSelection`）を確かめる
  var destination: CloudAIProviderKind { get }
  /// 最新の同意状態（同意の画面が保存した値）
  func currentConsent() -> ConsentState
  /// 表記を保つ辞書語（CTX-03 で送ってよい文脈）。読めなければ空
  func dictionaryTerms() async -> [String]
  /// 送る。同意がない・機密入力・予算を確かめられないなどの場合は送らずに理由を返す。
  ///
  /// - Parameter sensitivity: 選択範囲のある入力先で判定し直した結果。送る直前に呼ぶ（7章, AC-12）
  /// - Throws: 呼び出し元の Task がキャンセルされた場合
  func send(
    _ request: EditRequest,
    sensitivity: @escaping @MainActor () -> SensitiveInputDecision
  ) async throws(CancellationError) -> EditSendResult
}

/// `EditRequestSending.send(_:sensitivity:)` の結果。本文は含めない（編集案は `EditOutcome` の中だけに持つ）。
enum EditSendResult: Hashable, Sendable {
  /// `EditRouter` の結果（編集案、または編集できなかった理由）
  case outcome(EditOutcome)
  /// アプリ側の条件がそろわず、送らなかった
  case unavailable(EditSendUnavailableReason)
}

/// アプリ側の条件がそろわず、選択テキストを送らなかった理由（AC-12, AI-04, AI-05）。
enum EditSendUnavailableReason: Hashable, Sendable {
  /// Claude API キーが保存されていない
  case apiKeyNotSet
  /// Claude API キーを読み出せない（Mac のロック中・署名のないビルドなど）
  case apiKeyUnavailable
  /// 送信の設定（整形用モデル名など）を使えない
  case cloudUnavailable
  /// 予算上限を確かめられない（予算・単価表が未設定、通貨の不一致、累計を読み書きできない）
  case budgetUnavailable
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
  /// 録音中・認識中・応答待ちの表示を出す。`nil` なら閉じる。通知と違い、次の表示まで出したままにする
  func showStatus(_ status: EditModeStatus?)
}

/// Edit Mode の進行中の表示（AC-14）。本文は含めない。
enum EditModeStatus: Hashable, Sendable {
  /// 音声指示を録音している。もう一度ショートカットを押すと止める
  case listening
  /// 音声指示を認識している
  case recognizing
  /// 編集案を待っている
  case requesting
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

/// 音声指示を録音・認識できなかった理由。音声・認識テキストは含めない。
enum EditInstructionFailure: Hashable, Sendable {
  /// マイクの使用が許可されていない（PERM-01, PERM-02）
  case microphoneAccessDenied
  /// 録音を始められなかった（入力機器がないなど）
  case recordingFailed
  /// 認識に失敗した、または認識のテキストが空
  case recognitionFailed
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
  /// アプリ側の条件がそろわず送らなかった。選択範囲は変えていない
  case notSent(EditSendUnavailableReason)
  /// 音声認識のエンジンが選ばれていないため、Edit を始めない（録音と同じ「音声認識が設定されていません」）
  case speechRecognitionNotConfigured
  /// 録音のセッション中（または起動時の復旧中）のため、Edit を始めない
  case sessionInProgress
  /// 音声指示を録音できなかった
  case instructionNotRecorded(EditInstructionFailure)
  /// 置き換えた。`verified` が `false` なら読み戻しで確かめられていない（成功不明, INS-05）
  case replaced(verified: Bool)
  /// 元に戻した。`verified` が `false` なら読み戻しで確かめられていない
  case restored(verified: Bool)
  /// アプリの取り消し（⌘Z）などで、すでに元のテキストに戻っていた
  case alreadyRestored
}
