import Carbon.HIToolbox
import UtterCore

/// RegisterEventHotKey に渡すキーコードと修飾キー（REC-01）。
struct CarbonHotKeySpec: Hashable, Sendable {
  let keyCode: UInt32
  /// Carbon の修飾キー（cmdKey / optionKey / controlKey / shiftKey）
  let modifiers: UInt32

  /// 通常のキー組み合わせを Carbon の登録内容に変換する。
  ///
  /// 修飾キー単独と Fn を含む組み合わせは扱わない（#51 の判定待ち。Fn は RegisterEventHotKey の
  /// 修飾キーとして公式には挙げられていない）。
  static func make(for combination: KeyCombination) -> Result<CarbonHotKeySpec, HotKeySpecIssue> {
    guard let key = combination.key else { return .failure(.modifierOnly) }
    let modifiers = combination.modifiers
    if modifiers.contains(.function) {
      return .failure(.functionModifier)
    }
    guard let keyCode = MacKeyCodes.keyCode(for: key) else {
      return .failure(.unsupportedKey)
    }
    // F1〜F20 以外のキーを修飾キーなし・Shift だけで割り当てると、他アプリでの文字入力・編集操作
    // （space・return・矢印キー等を含む）そのものを奪うため割り当てない
    let typingSafeModifiers: ShortcutModifiers = [.command, .option, .control]
    if modifiers.isDisjoint(with: typingSafeModifiers) && !MacKeyCodes.isFunctionKey(key) {
      return .failure(.missingModifier)
    }
    return .success(CarbonHotKeySpec(keyCode: keyCode, modifiers: carbonModifiers(for: modifiers)))
  }

  /// UtterCore の修飾キーを Carbon の値にする。Fn は含めない（呼び出し側で除外済み）。
  static func carbonModifiers(for modifiers: ShortcutModifiers) -> UInt32 {
    var value = 0
    if modifiers.contains(.command) { value |= cmdKey }
    if modifiers.contains(.option) { value |= optionKey }
    if modifiers.contains(.control) { value |= controlKey }
    if modifiers.contains(.shift) { value |= shiftKey }
    return UInt32(value)
  }
}

/// RegisterEventHotKey で登録できない組み合わせの理由。
enum HotKeySpecIssue: Error, Hashable, Sendable {
  /// 修飾キー単独（#51 の判定待ち）
  case modifierOnly
  /// Fn / 地球儀キーを含む
  case functionModifier
  /// 対応表にないキー
  case unsupportedKey
  /// F1〜F20 以外のキーで、Command・Option・Control のいずれも含まない
  case missingModifier
}
