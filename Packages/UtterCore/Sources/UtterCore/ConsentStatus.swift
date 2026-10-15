/// 同意の状態。
public enum ConsentStatus: Hashable, Sendable, Codable {
  /// 一度も同意していない（既定）
  case notGranted
  /// 同意している
  case granted
  /// 同意した後に撤回した
  case revoked
}
