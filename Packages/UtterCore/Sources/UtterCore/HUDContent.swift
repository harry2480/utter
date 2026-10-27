/// HUD に表示する内容（REC-03, REC-05, 4.1節）。
///
/// 状態と通知の区分だけを持ち、発話本文・認識結果・エラー詳細は持たない。
public struct HUDContent: Hashable, Sendable {
  /// セッションの状態。セッション終了後に通知だけを残している間は `nil`。
  public let status: HUDStatus?
  /// 表示する通知。録音停止の通知（失敗の表示中に失敗の理由があればそれに置き換える）、整形の退避の通知の順に並べる。
  /// 上限到達で止めたセッションがローカル整形へ退避したときのように、同時に複数出る場合がある。
  public let notices: [HUDNotice]

  public init(status: HUDStatus?, notices: [HUDNotice]) {
    self.status = status
    self.notices = notices
  }

  /// 通知が1件以下の表示内容。
  public init(status: HUDStatus?, notice: HUDNotice?) {
    self.init(status: status, notices: notice.map { [$0] } ?? [])
  }

  /// 先頭の通知。通知がなければ `nil`。
  ///
  /// 録音停止と退避の通知が重なると先頭の1件しか返さないため、HUD の表示には `notices` を使う。
  public var notice: HUDNotice? {
    notices.first
  }
}

/// HUD に表示するセッションの状態（REC-03）。
public enum HUDStatus: Hashable, Sendable {
  case recording
  case recognizing
  case refining
  case inserting
  /// 失敗した段階
  case failed(SessionFailure)

  /// セッションの状態に対応する表示。待機中は `nil`。
  public init?(phase: SessionPhase) {
    switch phase {
    case .idle: return nil
    case .recording: self = .recording
    case .recognizing: self = .recognizing
    case .refining: self = .refining
    case .inserting: self = .inserting
    case .error(let failure): self = .failed(failure)
    }
  }
}

/// HUD で知らせる通知（REC-05, 4.1節）。
public enum HUDNotice: Hashable, Sendable {
  /// 最大録音時間に達したため自動停止した
  case maxRecordingDurationReached
  /// 音声バッファの上限に達したため自動停止した
  case audioBufferLimitReached
  /// 割り込み（電話着信・バックグラウンドへの移動・スリープ・入力機器の変更など）で録音を止めた（REC-04, iOS-PERF-03）
  case recordingInterrupted(RecordingInterruptionCause)
  /// 失敗の理由: 音声認識のエンジンが選ばれていない（Phase 0 の判定待ちで既定のエンジンを持たない, 11章）
  case speechRecognitionNotConfigured
  /// 失敗の理由: マイクの使用が拒否・制限されている（REC-04, PERM-02）
  case microphoneAccessDenied
  /// クラウド整形をせず、ローカル整形の結果に退避した（4.1節, AC-16）
  case refinementFellBack(RefinementFallbackNotice)
  /// 失敗の理由: クラウド STT を選んでいるが、送る条件がそろわない・認識できなかった（4章, AC-06, #188）
  case cloudSpeechRecognitionFailed(CloudSpeechRecognitionNotice)
  /// 入力モードが Realtime Direct（実験機能）だが、このセッションでは自動で無効にした（2.2節, AC-15）
  case realtimeDirectDisabled(RealtimeDirectFallbackNotice)
  /// 入力先がパスワード欄・セキュア入力・機密アプリ・除外アプリ、または判定できないため、録音を始めなかった（7章, AC-12）
  case recordingSuppressed(SensitiveInputReason)

  /// 録音の停止理由に対応する通知。利用者の停止操作では `nil`。
  public init?(stopReason: RecordingStopReason) {
    switch stopReason {
    case .manual: return nil
    case .maxDurationReached: self = .maxRecordingDurationReached
    case .bufferLimitReached: self = .audioBufferLimitReached
    case .interrupted(let cause): self = .recordingInterrupted(cause)
    }
  }
}

/// クラウド STT（#188）で認識できなかった理由のうち、HUD で区別して知らせる種類（4章, AC-06, AI-04, AI-06）。
///
/// 送る前の条件（同意・API キー・予算）と、送った後の失敗（AI-06 と同じ分け方）を分ける。
/// UtterSpeech の失敗の種類から導く（UtterCore は UtterSpeech に依存しないため、通知用に区分だけを持つ）。
/// 音声・認識テキスト・API キー・エラー詳細は持たない。
public enum CloudSpeechRecognitionNotice: Hashable, Sendable, CaseIterable {
  /// 音声送信の同意がない（AC-06）。送信していない
  case consentNotGranted
  /// API キーが保存されていない。送信していない
  case apiKeyNotSet
  /// API キーを読み出せない（Mac のロック中・署名のないビルドなど）。送信していない
  case apiKeyUnavailable
  /// 予算上限を確かめられない（予算・単価表が未設定、単価表にないモデル、通貨の不一致、累計を読み書きできない）。送信していない
  case budgetUnavailable
  /// 利用者が設定した予算上限を超える（AI-04）。送信していない
  case budgetExceeded
  /// 送れる音声の上限（長さ・サイズ）を超えた。送信していない
  case audioLimitExceeded
  /// 録音中に入力先が機密入力になった、または判定できない（7章, AC-12）。送信していない
  case sensitiveInput
  /// クラウド STT の設定（モデル名など）を使えない。送信していない
  case configurationUnavailable
  /// 応答待ちが上限時間を超えた
  case timeout
  /// API キーが失効・無効になった
  case authenticationExpired
  /// 利用枠（レート制限・クォータ）が不足している
  case quotaExceeded
  /// ネットワークに接続できない
  case networkUnavailable
  /// 応答を解釈できなかった
  case invalidResponse
}

/// Realtime Direct（2.2節, AC-15。実験機能）を自動で無効にした理由のうち、HUD で区別して知らせる種類。
///
/// 使えないと分かった時点で知らせ、Instant と同じく停止後にまとめて入力する（書き込んだ後にやめた場合はプレビューに出す）。
/// Apps の判定結果（許可リスト・機密入力・照合の失敗）から導く。入力欄の内容・認識テキスト・アプリ名は持たない。
public enum RealtimeDirectFallbackNotice: Hashable, Sendable, CaseIterable {
  /// 前面のアプリが対応を確かめたアプリでない・ターミナル系・入力欄を読めない・テキストを選択しているなど、使える条件を満たさない
  case unsupportedTarget
  /// 入力先がパスワード欄・セキュア入力・機密アプリ・除外アプリ、または判定できない（7章）
  case sensitiveInput
  /// クラウド STT（#188）は一括認識で、確定済みチャンクを録音中に流さない
  case cloudSpeechRecognition
  /// 書き込む前の照合で、入力欄の変更・フォーカスの移動などを検知した。入力欄には何も書き込んでいない
  case stoppedBeforeWriting
  /// 書き込みの途中で、入力欄の変更・フォーカスの移動などを検知した。書き込んだ分は入力欄に残し、全体をプレビューに出す
  case stoppedAfterWriting
}

/// ローカル整形へ退避した理由のうち、HUD で区別して知らせる種類（4.1節, AC-16, AI-06）。
///
/// UtterAI の退避理由から導く（UtterCore は UtterAI に依存しないため、通知用に区分だけを持つ）。
/// 発話本文・API キー・トークン・エラー詳細は持たない。
public enum RefinementFallbackNotice: Hashable, Sendable, CaseIterable {
  /// クラウド送信の同意がない（AC-06）
  case consentNotGranted
  /// 入力先が機密入力のため送信しなかった（7章, AC-12）
  case sensitiveInput
  /// 応答待ちが上限時間を超えた
  case timeout
  /// API キーや OAuth トークンが失効・無効になった
  case authenticationExpired
  /// プロバイダー側の利用枠が不足している
  case quotaExceeded
  /// 利用者が設定した予算上限を超える（AI-04）
  case budgetExceeded
  /// ネットワークに接続できない
  case networkUnavailable
  /// 応答を解釈できなかった
  case invalidResponse
  /// 呼び出し元はキャンセルしていないのに、プロバイダー側で要求が中断された
  case providerCancelled
  /// 応答が検証を通らなかった（4.1節）
  case validationFailed
}
