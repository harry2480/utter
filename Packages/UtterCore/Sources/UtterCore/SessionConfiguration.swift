/// 状態機械の設定。
public struct SessionConfiguration: Hashable, Sendable {
  /// 最大録音時間の既定値（REC-05: 暫定5分）。
  public static let defaultMaxRecordingDuration: Duration = .seconds(300)

  /// 1セッションの最大録音時間（REC-05）。
  public let maxRecordingDuration: Duration

  public init() {
    maxRecordingDuration = Self.defaultMaxRecordingDuration
  }

  public init(maxRecordingDuration: Duration) throws(SessionConfigurationError) {
    guard maxRecordingDuration > .zero else {
      throw .nonPositiveMaxRecordingDuration
    }
    self.maxRecordingDuration = maxRecordingDuration
  }
}

public enum SessionConfigurationError: Error, Hashable, Sendable {
  case nonPositiveMaxRecordingDuration
}
