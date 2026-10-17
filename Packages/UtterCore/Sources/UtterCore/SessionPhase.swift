/// セッションの状態（REC-06）。
///
/// 正常系は `idle → recording → recognizing → refining → inserting → idle` の順に進む。
/// 失敗時は `error` を経て `idle` に戻る。
public enum SessionPhase: Hashable, Sendable {
  case idle
  case recording
  case recognizing
  case refining
  case inserting
  case error(SessionFailure)
}

/// セッションが失敗した段階。本文やエラー詳細は持たない。
public enum SessionFailure: Hashable, Sendable {
  case recording
  case recognition
  case refinement
  case insertion
}

/// 録音を停止した理由。
public enum RecordingStopReason: Hashable, Sendable {
  /// 利用者の停止操作
  case manual
  /// 最大録音時間に到達した自動停止（REC-05）
  case maxDurationReached
  /// 音声バッファの上限に到達した自動停止（REC-05）
  case bufferLimitReached
  /// 画面ロック・電話着信などの割り込みによる停止（iOS-PERF-03）
  case interrupted(RecordingInterruptionCause)
}
