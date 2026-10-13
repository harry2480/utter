/// 共有結果の設定（iOS-IPC-02, iOS-IPC-03）。
public struct SharedResultConfiguration: Hashable, Sendable {
  /// 有効期限の既定値（iOS-IPC-02: 初期10分。検証で調整する）
  public static let defaultTimeToLive: Duration = .seconds(600)
  /// 挿入の猶予時間の既定値（暫定）
  public static let defaultInsertionGracePeriod: Duration = .seconds(30)

  /// 作成から挿入できなくなるまでの時間
  public let timeToLive: Duration
  /// 挿入を始めてから完了の記録を待つ時間。過ぎても挿入中のままなら、拡張が途中で終了したとみなす
  public let insertionGracePeriod: Duration

  public init() {
    timeToLive = Self.defaultTimeToLive
    insertionGracePeriod = Self.defaultInsertionGracePeriod
  }

  public init(
    timeToLive: Duration = defaultTimeToLive,
    insertionGracePeriod: Duration = defaultInsertionGracePeriod
  ) throws(SharedResultConfigurationError) {
    guard timeToLive > .zero else {
      throw .nonPositiveTimeToLive
    }
    guard insertionGracePeriod > .zero else {
      throw .nonPositiveInsertionGracePeriod
    }
    self.timeToLive = timeToLive
    self.insertionGracePeriod = insertionGracePeriod
  }
}

public enum SharedResultConfigurationError: Error, Hashable, Sendable {
  case nonPositiveTimeToLive
  case nonPositiveInsertionGracePeriod
}
