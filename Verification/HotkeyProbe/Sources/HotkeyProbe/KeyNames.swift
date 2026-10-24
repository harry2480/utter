import Carbon.HIToolbox
import CoreGraphics
import UtterCore

/// 通常のキーの名前と macOS の仮想キーコード（US 配列の位置）の対応。
///
/// ショートカットの指定と、システムのショートカット一覧の照合にだけ使う。
/// 入力されたキーの記録には使わない。
enum KeyNames {
  static let codes: [String: Int] = {
    var table: [String: Int] = [
      "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E,
      "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J,
      "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O,
      "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
      "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y,
      "z": kVK_ANSI_Z,
      "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
      "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
      "space": kVK_Space, "return": kVK_Return, "tab": kVK_Tab, "escape": kVK_Escape,
      "delete": kVK_Delete, "left": kVK_LeftArrow, "right": kVK_RightArrow,
      "up": kVK_UpArrow, "down": kVK_DownArrow,
      "eisu": kVK_JIS_Eisu, "kana": kVK_JIS_Kana,
    ]
    let functionKeys = [
      kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11,
      kVK_F12,
    ]
    for (index, code) in functionKeys.enumerated() {
      table["f\(index + 1)"] = code
    }
    return table
  }()

  static let names: [Int: String] = Dictionary(
    codes.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })

  /// 照合用の名前。表にないキーコードは `keycode-N` とする。
  static func shortcutKey(forCode code: Int) -> ShortcutKey? {
    ShortcutKey(rawValue: names[code] ?? "keycode-\(code)")
  }
}

/// `cmd+shift+space` 形式の指定を解釈した結果。
struct ParsedCombination {
  let combination: KeyCombination
  /// 通常のキーの仮想キーコード。修飾キー単独なら `nil`
  let keyCode: Int?

  /// 修飾キーの指定。左右の区別は UtterCore の `ShortcutModifiers` に表せないため、ここでは区別しない。
  static let modifierNames: [String: ShortcutModifiers] = [
    "cmd": .command, "command": .command,
    "opt": .option, "option": .option, "alt": .option,
    "ctrl": .control, "control": .control,
    "shift": .shift,
    "fn": .function,
  ]

  static func parse(_ text: String) throws(ProbeError) -> ParsedCombination {
    var modifiers: ShortcutModifiers = []
    var keyName: String?
    for token in text.lowercased().split(separator: "+").map(String.init) {
      if let modifier = modifierNames[token] {
        modifiers.insert(modifier)
      } else if keyName == nil {
        keyName = token == "esc" ? "escape" : token
      } else {
        throw .usage("通常のキーは1つだけ指定できます: \(text)")
      }
    }
    guard let keyName else {
      guard let combination = KeyCombination(modifierOnly: modifiers) else {
        throw .usage("キーの指定が空です: \(text)")
      }
      return ParsedCombination(combination: combination, keyCode: nil)
    }
    guard let code = KeyNames.codes[keyName], let key = ShortcutKey(rawValue: keyName) else {
      throw .usage("未対応のキー名です: \(keyName)（対応: a-z, 0-9, f1-f12, space, return, tab, escape 等）")
    }
    return ParsedCombination(
      combination: KeyCombination(key: key, modifiers: modifiers), keyCode: code)
  }

  /// RegisterEventHotKey に渡す Carbon の修飾キー。
  var carbonModifiers: UInt32 {
    var value = 0
    let modifiers = combination.modifiers
    if modifiers.contains(.command) { value |= cmdKey }
    if modifiers.contains(.option) { value |= optionKey }
    if modifiers.contains(.control) { value |= controlKey }
    if modifiers.contains(.shift) { value |= shiftKey }
    // Fn は RegisterEventHotKey の修飾キーとして公式には挙げられていない。結果を記録するために渡す
    if modifiers.contains(.function) { value |= Int(kEventKeyModifierFnMask) }
    return UInt32(value)
  }
}

/// 修飾キー単独ショートカットの対象キー。左右を区別できる。
struct ModifierTarget {
  let name: String
  /// 対象キーの flagsChanged のキーコード。左右どちらでもよい場合は2つ
  let keyCodes: Set<Int>
  /// 押下中を判定するフラグ（デバイス依存ビットまたは汎用マスク）
  let downMask: UInt64
  /// UtterCore に渡す修飾キー（左右の区別なし）
  let modifier: ShortcutModifiers
  /// 「他の修飾キーも押されている」の判定から除く汎用マスク
  let genericMask: CGEventFlags

  // IOKit の NX_DEVICE*KEYMASK（デバイス依存の左右ビット）
  private static let deviceLeftControl: UInt64 = 0x0000_0001
  private static let deviceLeftShift: UInt64 = 0x0000_0002
  private static let deviceRightShift: UInt64 = 0x0000_0004
  private static let deviceLeftCommand: UInt64 = 0x0000_0008
  private static let deviceRightCommand: UInt64 = 0x0000_0010
  private static let deviceLeftOption: UInt64 = 0x0000_0020
  private static let deviceRightOption: UInt64 = 0x0000_0040
  private static let deviceRightControl: UInt64 = 0x0000_2000

  static let all: [ModifierTarget] = [
    ModifierTarget(
      name: "fn", keyCodes: [kVK_Function], downMask: CGEventFlags.maskSecondaryFn.rawValue,
      modifier: .function, genericMask: .maskSecondaryFn),
    generic("command", [kVK_Command, kVK_RightCommand], .maskCommand, .command),
    generic("option", [kVK_Option, kVK_RightOption], .maskAlternate, .option),
    generic("control", [kVK_Control, kVK_RightControl], .maskControl, .control),
    generic("shift", [kVK_Shift, kVK_RightShift], .maskShift, .shift),
    sided("left-command", kVK_Command, deviceLeftCommand, .maskCommand, .command),
    sided("right-command", kVK_RightCommand, deviceRightCommand, .maskCommand, .command),
    sided("left-option", kVK_Option, deviceLeftOption, .maskAlternate, .option),
    sided("right-option", kVK_RightOption, deviceRightOption, .maskAlternate, .option),
    sided("left-control", kVK_Control, deviceLeftControl, .maskControl, .control),
    sided("right-control", kVK_RightControl, deviceRightControl, .maskControl, .control),
    sided("left-shift", kVK_Shift, deviceLeftShift, .maskShift, .shift),
    sided("right-shift", kVK_RightShift, deviceRightShift, .maskShift, .shift),
  ]

  static func named(_ name: String) -> ModifierTarget? {
    all.first { $0.name == name.lowercased() }
  }

  /// 他の修飾キー（対象と同じ種類の反対側を含む）が押されているか
  func othersDown(flags: UInt64) -> Bool {
    let genericOthers: CGEventFlags = [
      .maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn,
    ]
    let others = genericOthers.subtracting(genericMask)
    if flags & others.rawValue != 0 { return true }
    // 同じ種類の反対側: 汎用マスクは立っているが、対象の左右ビットだけでは説明できない
    if keyCodes.count == 1, modifier != .function {
      let sameKindDeviceBits = Self.deviceBits(for: modifier)
      return flags & (sameKindDeviceBits & ~downMask) != 0
    }
    return false
  }

  private static func deviceBits(for modifier: ShortcutModifiers) -> UInt64 {
    switch modifier {
    case .command: deviceLeftCommand | deviceRightCommand
    case .option: deviceLeftOption | deviceRightOption
    case .control: deviceLeftControl | deviceRightControl
    case .shift: deviceLeftShift | deviceRightShift
    default: 0
    }
  }

  private static func generic(
    _ name: String, _ codes: Set<Int>, _ mask: CGEventFlags, _ modifier: ShortcutModifiers
  ) -> ModifierTarget {
    ModifierTarget(
      name: name, keyCodes: codes, downMask: mask.rawValue, modifier: modifier, genericMask: mask)
  }

  private static func sided(
    _ name: String, _ code: Int, _ deviceBit: UInt64, _ mask: CGEventFlags,
    _ modifier: ShortcutModifiers
  ) -> ModifierTarget {
    ModifierTarget(
      name: name, keyCodes: [code], downMask: deviceBit, modifier: modifier, genericMask: mask)
  }
}

enum ProbeError: Error {
  case usage(String)
  case failed(String)
}
