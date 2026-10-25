/// ショートカットのキーの組み合わせ（REC-01, REC-02）。
///
/// 通常のキーと修飾キーの組み合わせか、修飾キー単独（Fn 等）のどちらか。
/// 修飾キー単独を実際に割り当てられるかは `ShortcutCapabilities` で判定する（Phase 0 で判断）。
public struct KeyCombination: Hashable, Sendable {
  /// 修飾キー以外のキー。修飾キー単独の組み合わせでは `nil`。
  public let key: ShortcutKey?
  public let modifiers: ShortcutModifiers

  /// 通常のキーと修飾キーの組み合わせ。修飾キーなしも表せる。
  public init(key: ShortcutKey, modifiers: ShortcutModifiers = []) {
    self.key = key
    self.modifiers = modifiers
  }

  /// 修飾キー単独の組み合わせ。修飾キーが空なら `nil`。
  public init?(modifierOnly modifiers: ShortcutModifiers) {
    guard !modifiers.isEmpty else { return nil }
    key = nil
    self.modifiers = modifiers
  }

  public var isModifierOnly: Bool {
    key == nil
  }

  /// 修飾キーなしの Esc。セッション中のキャンセルに予約されている（REC-01）。
  public static let escape = KeyCombination(key: .escape)
}

// MARK: - Codable

/// 設定への保存用（REC-01, REC-02）。修飾キー単独を割り当てられるかは保存時に判定せず、
/// 利用時に `ShortcutValidator` と `ShortcutCapabilities` で判定する。
extension KeyCombination: Codable {
  enum CodingKeys: String, CodingKey {
    case key
    case modifiers
  }

  /// キーも修飾キーもない組み合わせは作れないため、読み込みを失敗させる
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let modifiers = try container.decode(ShortcutModifiers.self, forKey: .modifiers)
    if let key = try container.decodeIfPresent(ShortcutKey.self, forKey: .key) {
      self.init(key: key, modifiers: modifiers)
    } else if let combination = KeyCombination(modifierOnly: modifiers) {
      self = combination
    } else {
      throw DecodingError.dataCorruptedError(
        forKey: .modifiers, in: container, debugDescription: "Empty key combination")
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(key, forKey: .key)
    try container.encode(modifiers, forKey: .modifiers)
  }
}
