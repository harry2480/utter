/// 現在の環境で割り当てられるショートカットの範囲（REC-02）。
///
/// 修飾キー単独（Fn 等）はイベントタップと追加権限が必要なため、対応可否を Phase 0 で判断する。
/// 判断前に決め打ちしないよう、既定値を持たせず呼び出し側が明示する。
public struct ShortcutCapabilities: Hashable, Sendable {
  /// 修飾キー単独の割当を受け付けるか
  public let supportsModifierOnly: Bool

  public init(supportsModifierOnly: Bool) {
    self.supportsModifierOnly = supportsModifierOnly
  }
}
