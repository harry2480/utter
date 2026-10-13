/// 共有結果の設定（iOS-IPC-02）。
public struct SharedResultConfiguration: Hashable, Sendable {
  /// 有効期限の既定値（iOS-IPC-02: 初期10分。検証で調整する）
  public static let defaultTimeToLive: Duration = .seconds(600)

  /// 作成から挿入できなくなるまでの時間
  public let timeToLive: Duration

  public init() {
    timeToLive = Self.defaultTimeToLive
  }

  public init(timeToLive: Duration) throws(SharedResultConfigurationError) {
    guard timeToLive > .zero else {
      throw .nonPositiveTimeToLive
    }
    self.timeToLive = timeToLive
  }
}

public enum SharedResultConfigurationError: Error, Hashable, Sendable {
  case nonPositiveTimeToLive
}
