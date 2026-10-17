import Foundation

/// ショートカットに使うキー（REC-01, REC-02）。
///
/// OS 固有のキーコードではなく、正規化した名前で表す（例: `"space"`, `"escape"`, `"a"`, `"f5"`）。
/// OS のキーイベントとの対応付けはアプリ側のアダプターが行う。
public struct ShortcutKey: RawRepresentable, Hashable, Sendable {
  public let rawValue: String

  /// 前後の空白を除いて小文字にそろえる。空になる名前は `nil`。
  public init?(rawValue: String) {
    let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !normalized.isEmpty else { return nil }
    self.rawValue = normalized
  }

  private init(normalized: String) {
    rawValue = normalized
  }

  /// セッション中のキャンセルに使うキー（REC-01）
  public static let escape = ShortcutKey(normalized: "escape")
  public static let space = ShortcutKey(normalized: "space")
}

/// ショートカットの修飾キー。
public struct ShortcutModifiers: OptionSet, Hashable, Sendable {
  public let rawValue: UInt8

  public init(rawValue: UInt8) {
    self.rawValue = rawValue
  }

  public static let command = ShortcutModifiers(rawValue: 1 << 0)
  public static let option = ShortcutModifiers(rawValue: 1 << 1)
  public static let control = ShortcutModifiers(rawValue: 1 << 2)
  public static let shift = ShortcutModifiers(rawValue: 1 << 3)
  /// Fn / 地球儀キー
  public static let function = ShortcutModifiers(rawValue: 1 << 4)
}
