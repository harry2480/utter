import Foundation
import UtterCore

/// ショートカットの表記（REC-01）。
///
/// - `parse`: `ctrl+option+k` 形式の指定を解釈する（開発用の起動引数で使う。HotkeyProbe と同じ書式）
/// - `display`: メニューに出す `⌃⌥K` 形式の表記にする
enum ShortcutNotation {
  private static let modifierNames: [String: ShortcutModifiers] = [
    "cmd": .command, "command": .command,
    "opt": .option, "option": .option, "alt": .option,
    "ctrl": .control, "control": .control,
    "shift": .shift,
    "fn": .function,
  ]

  /// 解釈できなければ `nil`。通常のキーは1つだけ。修飾キーだけの指定は修飾キー単独の組み合わせになる。
  static func parse(_ text: String) -> KeyCombination? {
    var modifiers: ShortcutModifiers = []
    var key: ShortcutKey?
    for token in text.lowercased().split(separator: "+", omittingEmptySubsequences: false) {
      let name = token.trimmingCharacters(in: .whitespaces)
      if let modifier = modifierNames[name] {
        modifiers.insert(modifier)
      } else if key == nil, let parsed = ShortcutKey(rawValue: name == "esc" ? "escape" : name) {
        key = parsed
      } else {
        return nil
      }
    }
    guard let key else { return KeyCombination(modifierOnly: modifiers) }
    return KeyCombination(key: key, modifiers: modifiers)
  }

  /// 修飾キーは macOS のメニューと同じ順（Fn ⌃ ⌥ ⇧ ⌘）に並べる。
  static func display(_ combination: KeyCombination) -> String {
    let modifiers = combination.modifiers
    var text = ""
    if modifiers.contains(.function) { text += "Fn" }
    if modifiers.contains(.control) { text += "⌃" }
    if modifiers.contains(.option) { text += "⌥" }
    if modifiers.contains(.shift) { text += "⇧" }
    if modifiers.contains(.command) { text += "⌘" }
    if let key = combination.key {
      text += keySymbols[key.rawValue] ?? key.rawValue.uppercased()
    }
    return text
  }

  private static let keySymbols: [String: String] = [
    "space": "Space", "return": "↩", "tab": "⇥", "escape": "⎋", "delete": "⌫",
    "left": "←", "right": "→", "up": "↑", "down": "↓", "eisu": "英数", "kana": "かな",
  ]
}
