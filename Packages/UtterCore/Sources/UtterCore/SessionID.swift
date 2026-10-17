import Foundation

/// 音声入力セッションを一意に識別する ID。
public struct SessionID: Hashable, Sendable, Codable {
  public let rawValue: UUID

  public init(rawValue: UUID = UUID()) {
    self.rawValue = rawValue
  }
}
