import Carbon.HIToolbox
import UtterCore

/// `ShortcutKey` の名前と macOS の仮想キーコードの対応（REC-01, REC-02）。
///
/// 仮想キーコードは配列に依存しない物理位置で、文字キーの名前は US 配列での位置を表す
/// （例: `"a"` は US 配列で A がある位置。Dvorak 等では別の文字になる）。
/// ショートカットの登録と、システムのショートカット一覧の照合にだけ使う。入力されたキーの記録には使わない。
enum MacKeyCodes {
  /// 名前 → 仮想キーコード。HotkeyProbe（#51）と同じ名前に F13〜F20 を加えたもの
  static let codesByName: [String: UInt32] = {
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
    for (index, code) in functionKeyCodes.enumerated() {
      table["f\(index + 1)"] = code
    }
    return table.mapValues { UInt32($0) }
  }()

  /// 仮想キーコード → 名前
  static let namesByCode: [UInt32: String] = Dictionary(
    codesByName.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })

  /// F1〜F20 の仮想キーコード（並びは F1 から）
  private static let functionKeyCodes = [
    kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
    kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
  ]

  /// 登録に使う仮想キーコード。対応表にないキーは `nil`。
  static func keyCode(for key: ShortcutKey) -> UInt32? {
    codesByName[key.rawValue]
  }

  /// 照合用のキー。対応表にないキーコードは `keycode-N` とし、utter の割当とは一致しない。
  static func key(forKeyCode code: UInt32) -> ShortcutKey? {
    ShortcutKey(rawValue: namesByCode[code] ?? "keycode-\(code)")
  }

  /// 矢印キーか
  static func isArrowKey(_ key: ShortcutKey) -> Bool {
    ["left", "right", "up", "down"].contains(key.rawValue)
  }

  /// F1〜F20 か。文字を入力しないため、修飾キーなしでも割り当てられる。
  static func isFunctionKey(_ key: ShortcutKey) -> Bool {
    guard let code = keyCode(for: key) else { return false }
    return functionKeyCodes.contains(Int(code))
  }
}
