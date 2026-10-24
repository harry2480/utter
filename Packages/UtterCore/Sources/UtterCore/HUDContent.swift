/// HUD に表示する内容（REC-03, REC-05）。
///
/// 状態と通知の区分だけを持ち、発話本文・認識結果・エラー詳細は持たない。
public struct HUDContent: Hashable, Sendable {
  /// セッションの状態。セッション終了後に通知だけを残している間は `nil`。
  public let status: HUDStatus?
  public let notice: HUDNotice?

  public init(status: HUDStatus?, notice: HUDNotice?) {
    self.status = status
    self.notice = notice
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

/// HUD で知らせる通知（REC-05）。
public enum HUDNotice: Hashable, Sendable {
  /// 最大録音時間に達したため自動停止した
  case maxRecordingDurationReached
  /// 音声バッファの上限に達したため自動停止した
  case audioBufferLimitReached
  /// 割り込み（電話着信・バックグラウンドへの移動など）で録音を止めた（iOS-PERF-03）
  case recordingInterrupted(RecordingInterruptionCause)
  /// 失敗の理由: 音声認識のエンジンが選ばれていない（Phase 0 の判定待ちで既定のエンジンを持たない, 11章）
  case speechRecognitionNotConfigured
  /// 失敗の理由: マイクの使用が拒否・制限されている（REC-04, PERM-02）
  case microphoneAccessDenied

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
