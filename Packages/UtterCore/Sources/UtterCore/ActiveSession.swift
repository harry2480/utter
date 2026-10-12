/// 進行中のセッションの情報。
public struct ActiveSession: Hashable, Sendable {
  public let id: SessionID
  public let sequence: UInt64
  public let startedAt: ContinuousClock.Instant
  /// 録音を停止した理由。録音中は `nil`。
  public let stopReason: RecordingStopReason?

  public var token: SessionToken {
    SessionToken(sessionID: id, sequence: sequence)
  }

  func advanced(stopReason: RecordingStopReason? = nil) -> ActiveSession {
    ActiveSession(
      id: id,
      sequence: sequence + 1,
      startedAt: startedAt,
      stopReason: stopReason ?? self.stopReason
    )
  }
}
