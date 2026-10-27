import UtterAI
import UtterCore

/// Edit Mode の通知・退避の文言（AC-14）。選択テキスト・音声指示・編集案の中身は含めない。
enum EditModeMessage {
  static func text(for notice: EditModeNotice) -> String {
    switch notice {
    case .couldNotStart(let failure): text(for: failure)
    case .notEdited(let reason): text(for: reason)
    case .notSent(let reason): text(for: reason)
    case .speechRecognitionNotConfigured:
      // 録音のセッションの HUD（`HUDNotice.speechRecognitionNotConfigured`）と同じ文言
      "音声認識が設定されていません"
    case .sessionInProgress: "音声入力の処理中のため、Edit を始めませんでした。終わってからもう一度押してください。"
    case .instructionNotRecorded(let failure): text(for: failure)
    case .replaced(verified: true): "選択範囲を置き換えました。"
    case .replaced(verified: false):
      "選択範囲を置き換えましたが、反映を確認できませんでした。入力欄を確かめてください。"
    case .restored(verified: true): "Edit を元に戻しました。"
    case .restored(verified: false):
      "Edit を元に戻しましたが、反映を確認できませんでした。入力欄を確かめてください。"
    case .alreadyRestored: "すでに元のテキストに戻っています。"
    }
  }

  static func text(for failure: EditStartFailure) -> String {
    switch failure {
    case .accessibilityNotTrusted:
      "アクセシビリティが許可されていないため、選択範囲を読めません。システム設定で utter を許可してください。"
    case .targetMissing: "入力欄が見つからないため、Edit を始められません。"
    case .sensitiveInput: "パスワード欄など、読み取らない入力先のため Edit を始めません。"
    case .noSelection: "編集するテキストを選択してから始めてください。"
    case .selectionUnreadable: "この入力欄では選択範囲を確かめられないため、Edit を始められません。"
    }
  }

  static func text(for reason: EditFailureReason) -> String {
    switch reason {
    case .emptyInstruction: "音声指示が空のため、編集しませんでした。"
    case .consentNotGranted:
      "選択テキストの送信に同意していないため、送信しませんでした。選択範囲は変えていません。"
    case .destinationMismatch: "送信先の設定が合わないため、送信しませんでした。選択範囲は変えていません。"
    case .sensitiveInputSuppressed:
      "パスワード欄など、送信しない入力先のため送信しませんでした。選択範囲は変えていません。"
    case .providerFailed(.budgetExceeded): "予算の上限に達するため、送信しませんでした。選択範囲は変えていません。"
    case .providerFailed(.timeout): "応答が時間内に届かなかったため、編集しませんでした。選択範囲は変えていません。"
    case .providerFailed: "編集案を取得できませんでした。選択範囲は変えていません。"
    case .validationFailed(.unchanged): "編集案が選択テキストと変わらなかったため、編集しませんでした。"
    case .validationFailed: "編集案として使えない応答だったため、編集しませんでした。選択範囲は変えていません。"
    }
  }

  static func text(for reason: EditSendUnavailableReason) -> String {
    switch reason {
    case .apiKeyNotSet:
      "Claude API キーが保存されていないため、送信しませんでした。設定画面の「API キー」で保存してください。"
    case .apiKeyUnavailable: "Claude API キーを読み出せないため、送信しませんでした。選択範囲は変えていません。"
    case .cloudUnavailable: "送信の設定（整形用モデル名）を使えないため、送信しませんでした。選択範囲は変えていません。"
    case .budgetUnavailable:
      "予算の上限を確かめられないため、送信しませんでした。設定画面の「費用」で月次予算と単価表を設定してください。"
    }
  }

  static func text(for failure: EditInstructionFailure) -> String {
    switch failure {
    case .microphoneAccessDenied:
      "マイクの使用が許可されていないため、指示を録音できません。システム設定で utter を許可してください。"
    case .recordingFailed: "指示を録音できませんでした。選択範囲は変えていません。"
    case .recognitionFailed: "指示を認識できませんでした。選択範囲は変えていません。"
    }
  }

  /// 進行中の表示
  static func text(for status: EditModeStatus) -> String {
    switch status {
    case .listening: "指示を話してください。終わったら、もう一度 Edit Mode のショートカットを押します。"
    case .recognizing: "指示を認識しています…"
    case .requesting: "編集案を待っています…"
    }
  }

  static func text(for cause: EditFallbackCause) -> String {
    switch cause {
    case .accessibilityNotTrusted:
      "アクセシビリティが許可されていないため、自動で書き換えませんでした。"
    case .targetMissing: "入力欄が見つからないため、自動で書き換えませんでした。"
    case .sensitiveInput: "パスワード欄など、自動で書き込まない入力先のため書き換えませんでした。"
    case .selectionChanged: "選択していたテキストが変わったため、自動で書き換えませんでした。"
    case .cannotReselect: "このアプリでは書き換える範囲を選び直せないため、自動で書き換えませんでした。"
    case .replacementFailed: "このアプリへ自動で書き換えられませんでした。"
    case .changedSinceCommit: "確定後に書き換えられていたため、自動で元に戻しませんでした。元のテキストです。"
    }
  }
}
