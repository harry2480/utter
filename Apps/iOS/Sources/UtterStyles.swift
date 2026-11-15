import SwiftUI

/// 本体アプリの見た目の部品（設計: 白いカード・丸いボタン・44pt 以上のタップ領域）。色は `UtterPalette`。
extension View {
  /// 白いカード。角は 16pt
  func utterCard(padding: EdgeInsets = EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
    -> some View
  {
    self
      .padding(padding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.utterCard, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
  }

  /// 画面の背景と、一覧の見た目をそろえる（`List` / `Form` 用）
  func utterListStyle() -> some View {
    self
      .scrollContentBackground(.hidden)
      .background(Color.utterBackground)
      .tint(Color.utterAccent)
  }
}

/// 塗りつぶしのボタン。`prominent` は青、そうでなければ濃い色
struct UtterFilledButtonStyle: ButtonStyle {
  enum Tone { case accent, strong }
  var tone: Tone = .accent
  var height: CGFloat = 48

  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    let fill = tone == .accent ? Color.utterAccent : Color.utterStrongFill
    let label = tone == .accent ? Color.utterOnAccent : Color.utterOnStrongFill
    configuration.label
      .font(.system(size: 17, weight: .bold))
      .foregroundStyle(label)
      .frame(maxWidth: .infinity, minHeight: height)
      .background(fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
      .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
  }
}

/// 枠だけのボタン
struct UtterOutlineButtonStyle: ButtonStyle {
  var role: ButtonRole?
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 15))
      .foregroundStyle(role == .destructive ? Color.red : Color.utterText)
      .padding(.horizontal, 16)
      .frame(maxWidth: .infinity, minHeight: 44)
      .background(Color.utterCard, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.utterLine, lineWidth: 1)
      )
      .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
  }
}

/// 状態の点（待機中・待機していない）
struct UtterStatusDot: View {
  let color: Color
  var body: some View {
    Circle().fill(color).frame(width: 12, height: 12).accessibilityHidden(true)
  }
}

/// 文字を外へ送ることを示す小さなラベル（AC-06）
struct UtterWarningPill: View {
  let text: String
  var body: some View {
    Text(text)
      .font(.system(size: 12))
      .padding(.horizontal, 8)
      .padding(.vertical, 2)
      .foregroundStyle(Color.utterWarningText)
      .background(Color.utterWarningFill, in: Capsule())
  }
}

/// カードの見出し（小さな太字）
struct UtterSectionLabel: View {
  let text: String
  init(_ text: String) { self.text = text }
  var body: some View {
    Text(text)
      .font(.system(size: 13, weight: .bold))
      .foregroundStyle(Color.utterSecondary)
      .accessibilityAddTraits(.isHeader)
  }
}
