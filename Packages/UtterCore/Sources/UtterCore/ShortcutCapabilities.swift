/// 現在の環境で使えるショートカットの機能の範囲（REC-01, REC-02）。
///
/// 修飾キー単独（Fn 等）の割当と、セッション中だけの Esc 捕捉はイベントタップと追加権限が必要なため、
/// 対応可否を Phase 0（#51）で判断する。判断前に決め打ちしないよう、イニシャライザには既定値を持たせず
/// 呼び出し側が明示する。どちらも使わない範囲は `keyCombinationsOnly`。
public struct ShortcutCapabilities: Hashable, Sendable {
  /// 修飾キー単独の割当を受け付けるか
  public let supportsModifierOnly: Bool
  /// セッション中だけ Esc を捕捉してキャンセルに使うか（REC-01）
  public let supportsEscapeCapture: Bool

  public init(supportsModifierOnly: Bool, supportsEscapeCapture: Bool) {
    self.supportsModifierOnly = supportsModifierOnly
    self.supportsEscapeCapture = supportsEscapeCapture
  }

  /// 通常のキー組み合わせだけを使い、イベントタップを作らない範囲（追加権限なし, PERM-01）
  public static let keyCombinationsOnly = ShortcutCapabilities(
    supportsModifierOnly: false, supportsEscapeCapture: false)
}
