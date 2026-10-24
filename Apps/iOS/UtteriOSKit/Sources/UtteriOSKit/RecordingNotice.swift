import UtterCore
import UtterPersistence

/// 録音を自動で止めた理由（REC-05, iOS-PERF-03）。止めた後の音声は通常どおり処理する。
public enum RecordingStopNotice: Hashable, Sendable {
  /// 最大録音時間に達した
  case maxDurationReached
  /// 音声バッファの上限に達した
  case bufferLimitReached
  /// 割り込みで止めた
  case interrupted(RecordingInterruptionCause)

  public var message: String {
    switch self {
    case .maxDurationReached: "最大録音時間に達したため、録音を止めました。"
    case .bufferLimitReached: "録音できる量の上限に達したため、録音を止めました。"
    case .interrupted(let cause): "\(cause.message)ため、録音を止めました。"
    }
  }
}

/// セッションを完了できなかった理由。無言で終わらせないために表示する（REC-05, iOS-07）。
///
/// 本文・音声・エラーの詳細は持たない。
public enum RecordingFailure: Hashable, Sendable {
  /// マイクの利用を許可されていない
  case microphoneDenied
  /// 録音を開始できなかった
  case recordingUnavailable
  /// 割り込みで止めたが、処理できる音声がなかった
  case interruptedWithoutAudio(RecordingInterruptionCause)
  /// 音声認識が未設定（STT エンジンの判定待ち）、またはモデルを使えない
  case recognizerUnavailable
  /// 音声認識に失敗した
  case recognitionFailed
  /// 認識結果が空だった
  case noSpeech
  /// 結果を保存できなかった。本文はこの画面でだけコピーできる
  case saveFailed

  public var message: String {
    switch self {
    case .microphoneDenied:
      "マイクの利用が許可されていません。設定アプリで utter のマイクを許可してください。"
    case .recordingUnavailable: "録音を開始できませんでした。"
    case .interruptedWithoutAudio(let cause): "\(cause.message)ため、録音を中止しました。音声はありません。"
    case .recognizerUnavailable: "音声認識が設定されていないため、文字にしていません。音声は保存していません。"
    case .recognitionFailed: "音声認識に失敗しました。"
    case .noSpeech: "音声を文字にできませんでした。"
    case .saveFailed: "結果を保存できませんでした。下の本文をコピーできます。"
    }
  }
}

/// 結果をコピーした操作の結果（iOS-07）。
public enum ResultCopyNotice: Hashable, Sendable {
  case copied
  /// 期限切れ・挿入済み・キーボードが挿入中などでコピーしなかった
  case notCopied
  /// 保存先を読み書きできず、コピーしなかった（端末のロック中・保存先の不具合など。種類は区別しない）
  case failed

  public var message: String {
    switch self {
    case .copied: "コピーしました。"
    case .notCopied: "この結果はコピーできません。"
    case .failed: "結果を読み書きできず、コピーしませんでした。端末のロック中なら、解除してからもう一度試してください。"
    }
  }
}

extension RecordingInterruptionCause {
  var message: String {
    switch self {
    case .audioInterruption: "電話の着信などでマイクが使えなくなった"
    case .inputDeviceLost: "マイクの接続が切れた"
    case .mediaServicesReset: "録音機能がリセットされた"
    case .movedToBackground: "画面のロックやアプリの切り替えがあった"
    case .thermalState: "端末の温度が高くなった"
    case .lowPowerMode: "低電力モードになった"
    }
  }
}

extension SharedResultSharing {
  /// 救済画面に出す、キーボードと共有しているかの説明
  public var message: String {
    switch self {
    case .appGroup:
      "結果はキーボードと共有しています。"
    case .appLocalOnly(.appGroupNotConfigured):
      "App Group が未設定のため、結果はこのアプリの中にだけ保存し、キーボードとは共有しません。"
    case .appLocalOnly(.appGroupUnavailable):
      "App Group を開けなかったため、結果はこのアプリの中にだけ保存し、キーボードとは共有しません。"
    }
  }
}
