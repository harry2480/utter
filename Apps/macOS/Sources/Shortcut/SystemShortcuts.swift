import Carbon.HIToolbox
import Foundation
import UtterCore

/// システムのショートカット（システム設定 > キーボード > キーボードショートカット）の一覧（REC-02）。
///
/// CopySymbolicHotKeys で取得する（権限は不要）。RegisterEventHotKey の登録が成功しても、
/// システムが先に処理する組み合わせは utter に届かないため、登録前にここで競合を検出する。
/// 他のアプリが独自に登録したショートカットやメニューのショートカットは含まれない。
/// Fn / 地球儀キーの割り当てと、Control 2回押し等の音声入力ショートカットも一覧に出ない（HotkeyProbe の結果）。
enum SystemShortcuts {
  /// CopySymbolicHotKeys の1項目
  struct Entry: Hashable, Sendable {
    let keyCode: Int
    let rawModifiers: Int
    let enabled: Bool
  }

  /// 修飾キーの値の形式
  enum Format: Hashable, Sendable {
    /// cmdKey = 0x100、shiftKey = 0x200、optionKey = 0x800、controlKey = 0x1000、Fn = 0x20000
    case carbon
    /// NSEvent.ModifierFlags（shift = 0x20000、command = 0x100000 等）
    case nsEvent
  }

  /// 有効なシステムのショートカットを `ShortcutValidator` の比較対象として返す。取得できなければ空。
  static func loadEnabledBindings() -> [ShortcutBinding] {
    var unmanaged: Unmanaged<CFArray>?
    guard CopySymbolicHotKeys(&unmanaged) == noErr, let unmanaged else { return [] }
    let array = unmanaged.takeRetainedValue() as NSArray
    let entries: [Entry?] = array.map { element in
      guard let dict = element as? [String: Any],
        let code = (dict["kHISymbolicHotKeyCode"] as? NSNumber)?.intValue,
        let raw = (dict["kHISymbolicHotKeyModifiers"] as? NSNumber)?.intValue
      else { return nil }
      let enabled = (dict["kHISymbolicHotKeyEnabled"] as? NSNumber)?.boolValue ?? true
      return Entry(keyCode: code, rawModifiers: raw, enabled: enabled)
    }
    return enabledBindings(from: entries)
  }

  /// 一覧のうち有効な項目を割当にする。ID は一覧上の位置（システム設定の項目名は取得できない）。
  static func enabledBindings(from entries: [Entry?]) -> [ShortcutBinding] {
    let format = format(of: entries.compactMap { $0 }) ?? .carbon
    return entries.enumerated().compactMap { index, entry in
      guard let entry, entry.enabled, entry.keyCode >= 0,
        let key = MacKeyCodes.key(forKeyCode: UInt32(entry.keyCode))
      else { return nil }
      var modifiers = modifiers(fromRaw: entry.rawModifiers, format: format)
      // F キー・矢印キーの項目には Fn のビットが付くことがある（キー自体が Fn 層にあるため）。
      // そのままでは utter の割当（Fn を含まない）と一致せず競合を見逃すため、外して照合する
      if MacKeyCodes.isFunctionKey(key) || MacKeyCodes.isArrowKey(key) {
        modifiers.remove(.function)
      }
      let combination = KeyCombination(key: key, modifiers: modifiers)
      return ShortcutBinding(id: "system.index.\(index)", combination: combination)
    }
  }

  /// 一覧全体から修飾キーの形式を決める。決まらなければ `nil`（呼び出し側は Carbon 形式として扱う）。
  ///
  /// 0x20000 は Carbon では Fn、NSEvent では Shift になるため、項目ごとには決められない。
  /// Carbon 形式のビット（0x1F00）を持つ項目が1つでもあれば Carbon 形式。
  /// macOS 26 の実機では Carbon 形式で返った（HotkeyProbe の結果）。
  static func format(of entries: [Entry]) -> Format? {
    if entries.contains(where: { $0.rawModifiers & carbonBits != 0 }) { return .carbon }
    if entries.contains(where: { $0.rawModifiers & nsEventOnlyBits != 0 }) { return .nsEvent }
    return nil
  }

  /// 修飾キーの値を UtterCore の型にする。
  static func modifiers(fromRaw raw: Int, format: Format) -> ShortcutModifiers {
    var result: ShortcutModifiers = []
    switch format {
    case .nsEvent:
      if raw & 0x10_0000 != 0 { result.insert(.command) }
      if raw & 0x08_0000 != 0 { result.insert(.option) }
      if raw & 0x04_0000 != 0 { result.insert(.control) }
      if raw & 0x02_0000 != 0 { result.insert(.shift) }
      if raw & 0x80_0000 != 0 { result.insert(.function) }
    case .carbon:
      if raw & cmdKey != 0 { result.insert(.command) }
      if raw & optionKey != 0 { result.insert(.option) }
      if raw & controlKey != 0 { result.insert(.control) }
      if raw & shiftKey != 0 { result.insert(.shift) }
      if raw & carbonFn != 0 { result.insert(.function) }
    }
    return result
  }

  private static let carbonBits = 0x1F00
  private static let carbonFn = Int(kEventKeyModifierFnMask)
  /// NSEvent 形式にしかないビット（control / option / command / function）
  private static let nsEventOnlyBits = 0x04_0000 | 0x08_0000 | 0x10_0000 | 0x80_0000
}
