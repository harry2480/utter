import SwiftUI
import UIKit

/// iOS の本体アプリとキーボード拡張で共有する、見た目の色（設計: 背景・カード・文字・アクセント・警告）。
///
/// 色の値だけを持つ。ライト/ダークで切り替わる色は `UIColor` の動的な色にし、SwiftUI からは `Color(uiColor:)` で使う。
/// キーボードの録音中・認識中の帯は、どちらのモードでも暗い帯にする（`band…` の色は固定）。
enum UtterPalette {
  private static func hex(_ value: UInt32) -> UIColor {
    UIColor(
      red: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
      blue: CGFloat(value & 0xFF) / 255, alpha: 1)
  }

  private static func dynamic(light: UInt32, dark: UInt32) -> UIColor {
    UIColor { $0.userInterfaceStyle == .dark ? hex(dark) : hex(light) }
  }

  // 画面・カード・文字
  static let background = dynamic(light: 0xF3F4F1, dark: 0x101114)
  static let card = dynamic(light: 0xFFFFFF, dark: 0x1B1D23)
  static let text = dynamic(light: 0x15171C, dark: 0xF2F3F5)
  /// 補助の文字。ライトで #4A4F5A（背景に対して 4.5:1 以上）
  static let secondaryText = dynamic(light: 0x4A4F5A, dark: 0xA9AEBA)
  static let line = dynamic(light: 0xDADDE3, dark: 0x3A3E48)
  static let accent = dynamic(light: 0x1F4FD8, dark: 0x8FB4FF)
  /// アクセントの上に載せる文字
  static let onAccent = dynamic(light: 0xFFFFFF, dark: 0x101114)
  /// 待機していないことを示す点
  static let idleDot = dynamic(light: 0x6B7180, dark: 0x8E94A3)
  /// 暗い塗りのボタンとその上の文字
  static let strongFill = dynamic(light: 0x15171C, dark: 0xF2F3F5)
  static let onStrongFill = dynamic(light: 0xFFFFFF, dark: 0x15171C)
  /// 文字を外へ送ることを示す印
  static let warningFill = dynamic(light: 0xFCEBDD, dark: 0x4A2A14)
  static let warningText = dynamic(light: 0x8A2E08, dark: 0xFFB68A)
  static let highlight = dynamic(light: 0xE6ECFB, dark: 0x24304F)

  // キーボード
  static let keyboardBackground = dynamic(light: 0xD6D9DE, dark: 0x1B1D23)
  static let key = dynamic(light: 0xFFFFFF, dark: 0x4A4F5A)
  static let functionKey = dynamic(light: 0xAEB3BD, dark: 0x2C2F38)
  static let keyShadow = dynamic(light: 0x8E94A3, dark: 0x101114)
  static let segmentTrack = dynamic(light: 0xECEEF1, dark: 0x2C2F38)

  // 暗い帯（録音中・認識中）。どちらのモードでも同じ
  static let band = hex(0x1B1D23)
  static let bandRaised = hex(0x2C2F38)
  static let bandText = hex(0xF2F3F5)
  static let bandSecondaryText = hex(0xA9AEBA)
  static let bandBodyText = hex(0xD5D8DF)
  static let bandAccent = hex(0x8FB4FF)
  static let bandTrack = hex(0x3A3E48)
  static let bandLine = hex(0x4A4F5A)
  static let bandWarningFill = hex(0x4A2A14)
  static let bandWarningText = hex(0xFFB68A)
}

extension Color {
  /// 共有の色（`UtterPalette`）を SwiftUI で使う
  static let utterBackground = Color(uiColor: UtterPalette.background)
  static let utterCard = Color(uiColor: UtterPalette.card)
  static let utterText = Color(uiColor: UtterPalette.text)
  static let utterSecondary = Color(uiColor: UtterPalette.secondaryText)
  static let utterLine = Color(uiColor: UtterPalette.line)
  static let utterAccent = Color(uiColor: UtterPalette.accent)
  static let utterOnAccent = Color(uiColor: UtterPalette.onAccent)
  static let utterIdleDot = Color(uiColor: UtterPalette.idleDot)
  static let utterStrongFill = Color(uiColor: UtterPalette.strongFill)
  static let utterOnStrongFill = Color(uiColor: UtterPalette.onStrongFill)
  static let utterWarningFill = Color(uiColor: UtterPalette.warningFill)
  static let utterWarningText = Color(uiColor: UtterPalette.warningText)
}
