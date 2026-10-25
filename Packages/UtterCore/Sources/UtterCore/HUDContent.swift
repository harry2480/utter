/// HUD に表示する内容（REC-03, REC-05, 4.1節）。
///
/// 状態と通知の区分だけを持ち、発話本文・認識結果・エラー詳細は持たない。
public struct HUDContent: Hashable, Sendable {
  /// セッションの状態。セッション終了後に通知だけを残している間は `nil`。
  public let status: HUDStatus?
  /// 表示する通知。録音停止の通知、整形の退避の通知の順に並べる。
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
