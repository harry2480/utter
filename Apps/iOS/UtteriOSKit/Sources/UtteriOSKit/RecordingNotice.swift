import UtterAI
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

/// クラウド整形を使えず、ローカル整形の結果を保存したことの通知（4.1節, AI-06）。
///
/// Local Basic を選んでいる・同意していない・結線していない・Raw モードのときは送信しないのが正しい動作のため通知しない。
/// 本文・API キー・エラーの詳細は持たない。
public enum RefinementNotice: Hashable, Sendable {
  /// クラウド整形の設定（モデル名など）を使えない
  case configurationUnavailable
  /// 同意しているが API キーが保存されていない
  case apiKeyNotSet
  /// API キーを読み出せない
  case apiKeyUnavailable
  /// 予算上限を確かめられない
  case budgetUnavailable(CloudBudgetUnavailableReason)
  /// 予算の上限に達する
  case budgetExceeded
  /// 認証に失敗した（API キーの誤り・失効）
  case authenticationFailed
  /// 利用枠が不足している
  case quotaExceeded
  /// 応答が上限時間内に返らなかった
  case timeout
  /// ネットワークにつながらない・サービスの一時的な障害
  case networkUnavailable
  /// 応答を整形結果として使えなかった（検証失敗・解釈できない応答）
  case unusableResponse

  /// 通知しない経路なら `nil`
  init?(route: SessionRefinementRoute) {
    switch route {
    case .cloud, .localOnly(.cloudNotConfigured), .localOnly(.rawMode),
      .localOnly(.localEngineSelected), .localOnly(.consentNotGranted):
      return nil
    case .localOnly(.cloudUnavailable): self = .configurationUnavailable
    case .localOnly(.apiKeyNotSet): self = .apiKeyNotSet
    case .localOnly(.apiKeyUnavailable): self = .apiKeyUnavailable
    case .localOnly(.budgetUnavailable(let reason)): self = .budgetUnavailable(reason)
    case .cloudFallback(.consentNotGranted): return nil
    case .cloudFallback(.validationFailed): self = .unusableResponse
    case .cloudFallback(.providerFailed(let error)):
      switch error {
      case .budgetExceeded: self = .budgetExceeded
      case .authenticationExpired: self = .authenticationFailed
      case .quotaExceeded: self = .quotaExceeded
      case .timeout: self = .timeout
      case .networkUnavailable: self = .networkUnavailable
      case .invalidResponse, .cancelled: self = .unusableResponse
      }
    }
  }

  public var message: String {
    let detail =
      switch self {
      case .configurationUnavailable: "クラウド整形の設定（モデル名など）を使えなかった"
      case .apiKeyNotSet: "Claude API キーが設定されていない"
      case .apiKeyUnavailable: "Claude API キーを読み出せなかった（端末のロック中など）"
      case .budgetUnavailable(.notConfigured): "月次予算と単価表が設定されていない"
      case .budgetUnavailable(.currencyMismatch): "月次予算と単価表の通貨が一致しない"
      case .budgetUnavailable(.modelNotPriced): "整形に使うモデルの単価が単価表にない"
      case .budgetUnavailable(.usageUnavailable): "推定費用の累計を読み書きできなかった"
      case .budgetUnavailable(.previousRefinementInProgress): "前の整形の推定費用をまだ記録している"
      case .budgetExceeded: "今月の予算の上限に達する"
      case .authenticationFailed: "Claude API キーが正しくないか、使えなくなっている"
      case .quotaExceeded: "Claude API の利用枠が不足している"
      case .timeout: "Claude の応答が時間内に返らなかった"
      case .networkUnavailable: "Claude に接続できなかった"
      case .unusableResponse: "Claude の応答を整形結果として使えなかった"
      }
    return "\(detail)ため、Claude では整形せず、端末内の整形（Local Basic）の結果を保存しました。"
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
