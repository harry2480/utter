import Foundation

/// 共有結果の設定（iOS-IPC-02, iOS-IPC-03）。
public struct SharedResultConfiguration: Hashable, Sendable, Codable {
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

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    let ttlComponents = timeToLive.components
    let ttl = TimeInterval(ttlComponents.seconds) + TimeInterval(ttlComponents.attoseconds) / 1e18
    try container.encode(ttl, forKey: .timeToLive)
    let gracePeriodComponents = insertionGracePeriod.components
    let gracePeriod =
      TimeInterval(gracePeriodComponents.seconds) + TimeInterval(gracePeriodComponents.attoseconds)
      / 1e18
    try container.encode(gracePeriod, forKey: .insertionGracePeriod)
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let ttl = try container.decode(TimeInterval.self, forKey: .timeToLive)
    let gracePeriod = try container.decode(TimeInterval.self, forKey: .insertionGracePeriod)
    try self.init(
      timeToLive: Duration(
        secondsComponent: Int64(ttl),
        attosecondsComponent: Int64((ttl.truncatingRemainder(dividingBy: 1)) * 1e18)),
      insertionGracePeriod: Duration(
        secondsComponent: Int64(gracePeriod),
        attosecondsComponent: Int64((gracePeriod.truncatingRemainder(dividingBy: 1)) * 1e18))
    )
  }

  private enum CodingKeys: String, CodingKey {
    case timeToLive
    case insertionGracePeriod
  }
}

public enum SharedResultConfigurationError: Error, Hashable, Sendable {
  case nonPositiveTimeToLive
  case nonPositiveInsertionGracePeriod
}
