import AppKit
import SwiftUI

/// macOS の画面で共通に使う色（アーティファクト設計のトークン）。
///
/// 画面ごとに色を書かず、ここへ集める。HUD は常に暗い面、設定・初回設定は明暗に追従する。
enum UtterTheme {
  /// HUD の面（暗）
  static let hudSurface = Color(hex: 0x1B1D23)
  /// HUD の中の一段明るい面（チップ・本文ブロック）
  static let hudRaised = Color(hex: 0x2C2F38)
  /// HUD の主文字
  static let hudText = Color(hex: 0xF2F3F5)
  /// HUD の補助文字
  static let hudSecondary = Color(hex: 0xA9AEBA)
  /// HUD の本文（一段おだやか）
  static let hudBody = Color(hex: 0xD5D8DF)
  /// HUD の罫線・キーの枠
  static let hudStroke = Color(hex: 0x4A4F5A)
  /// HUD の未到達の段階
  static let hudTrack = Color(hex: 0x3A3E48)
  /// HUD の強調（淡青）
  static let hudAccent = Color(hex: 0x8FB4FF)
  /// 警告（クラウド送信・退避・エラー）の文字
  static let hudWarning = Color(hex: 0xFFB68A)
  /// 警告の面
  static let hudWarningFill = Color(hex: 0x4A2A14)

  /// 設定・初回設定の背景（明）。暗い外観ではシステムの背景に任せる
  static let pageBackground = Color(
    nsColor: NSColor(name: nil) { appearance in
      appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        ? NSColor.windowBackgroundColor
        : NSColor(srgbRed: 0xF3 / 255, green: 0xF4 / 255, blue: 0xF1 / 255, alpha: 1)
    })

  /// 明るい画面のアクセント
  static let accent = Color(hex: 0x1F4FD8)
  /// 明るい画面の警告面・文字
  static let warningFill = Color(hex: 0xFCEBDD)
  static let warningText = Color(hex: 0x8A2E08)
}

extension Color {
  fileprivate init(hex: UInt32) {
    self.init(
      .sRGB,
      red: Double((hex >> 16) & 0xFF) / 255,
      green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255)
  }
}
