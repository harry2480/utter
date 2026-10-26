import Carbon.HIToolbox
import CoreGraphics
import UtterCore

/// 修飾キー単独ショートカットに使う物理キー（REC-01, REC-02。#51 の判定待ち）。
///
/// UtterCore の `ShortcutModifiers` は左右を区別しないため、どちらの側のキーかはここで持つ。
/// 右 Option だけを割り当てて左 Option は文字入力に使う、といった使い分けのため、Fn 以外は左右を指定する。
/// 名前（rawValue）は HotkeyProbe の `modifier` の対象名と同じ。
enum ModifierOnlyKey: String, CaseIterable, Hashable, Sendable {
  case function = "fn"
  case leftCommand = "left-command"
  case rightCommand = "right-command"
  case leftOption = "left-option"
  case rightOption = "right-option"
  case leftControl = "left-control"
  case rightControl = "right-control"
  case leftShift = "left-shift"
  case rightShift = "right-shift"

  /// UtterCore に渡す修飾キー（左右の区別なし）。競合検出と、PTT での Esc の判定に使う
  var modifier: ShortcutModifiers {
    switch self {
    case .function: .function
    case .leftCommand, .rightCommand: .command
    case .leftOption, .rightOption: .option
    case .leftControl, .rightControl: .control
    case .leftShift, .rightShift: .shift
    }
  }

  /// UtterCore の修飾キー単独の組み合わせ
  var combination: KeyCombination {
    guard let combination = KeyCombination(modifierOnly: modifier) else {
      preconditionFailure("修飾キーが空")
    }
    return combination
  }

  /// flagsChanged で届くキーコード
  var keyCode: Int {
    switch self {
    case .function: kVK_Function
    case .leftCommand: kVK_Command
    case .rightCommand: kVK_RightCommand
    case .leftOption: kVK_Option
    case .rightOption: kVK_RightOption
    case .leftControl: kVK_Control
    case .rightControl: kVK_RightControl
    case .leftShift: kVK_Shift
    case .rightShift: kVK_RightShift
    }
  }

  /// 押下中を判定するフラグ。Fn は汎用マスク、それ以外は左右を区別するデバイス依存ビット
  var downMask: UInt64 {
    switch self {
    case .function: CGEventFlags.maskSecondaryFn.rawValue
    case .leftCommand: DeviceFlags.leftCommand
    case .rightCommand: DeviceFlags.rightCommand
    case .leftOption: DeviceFlags.leftOption
    case .rightOption: DeviceFlags.rightOption
    case .leftControl: DeviceFlags.leftControl
    case .rightControl: DeviceFlags.rightControl
    case .leftShift: DeviceFlags.leftShift
    case .rightShift: DeviceFlags.rightShift
    }
  }

  /// 修飾キー単独の組み合わせに対応する物理キー。左右を決められるのは Fn だけで、それ以外は `nil`。
  init?(combination: KeyCombination) {
    guard combination.isModifierOnly, combination.modifiers == .function else { return nil }
    self = .function
  }

  /// 他の修飾キー（同じ種類の反対側を含む）が押されているか。押下時に他の修飾キーと同時なら
  /// 別のショートカットの途中とみなし、修飾キー単独としては扱わない。
  func othersDown(flags: UInt64) -> Bool {
    let generic: CGEventFlags = [
      .maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn,
    ]
    let others = generic.subtracting(Self.genericMask(for: modifier))
    if flags & others.rawValue != 0 { return true }
    // 同じ種類の反対側: 対象の左右ビット以外の、同じ種類のデバイス依存ビットが立っている
    return flags & (DeviceFlags.bits(for: modifier) & ~downMask) != 0
  }

  private static func genericMask(for modifier: ShortcutModifiers) -> CGEventFlags {
    switch modifier {
    case .command: .maskCommand
    case .option: .maskAlternate
    case .control: .maskControl
    case .shift: .maskShift
    default: .maskSecondaryFn
    }
  }
}

/// IOKit の NX_DEVICE*KEYMASK（CGEventFlags の下位にある、左右を区別するデバイス依存ビット）。
enum DeviceFlags {
  static let leftControl: UInt64 = 0x0000_0001
  static let leftShift: UInt64 = 0x0000_0002
  static let rightShift: UInt64 = 0x0000_0004
  static let leftCommand: UInt64 = 0x0000_0008
  static let rightCommand: UInt64 = 0x0000_0010
  static let leftOption: UInt64 = 0x0000_0020
  static let rightOption: UInt64 = 0x0000_0040
  static let rightControl: UInt64 = 0x0000_2000

  /// 同じ種類の左右両方のビット。Fn は左右がないため 0
  static func bits(for modifier: ShortcutModifiers) -> UInt64 {
    switch modifier {
    case .command: leftCommand | rightCommand
    case .option: leftOption | rightOption
    case .control: leftControl | rightControl
    case .shift: leftShift | rightShift
    default: 0
    }
  }
}
