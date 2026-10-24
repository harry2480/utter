import SwiftUI
import UtterCore

/// HUD の中身（REC-03, REC-05, AC-16）。文言は `HUDPresentation` のものをそのまま出す。
struct HUDView: View {
  let presentation: HUDPresentation

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      indicator
        .frame(width: 18)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(presentation.title)
          .font(.headline)
        // 録音停止（または失敗の理由）と整形の退避の通知が重なると複数行になる（REC-05, AC-16）
        ForEach(Array(presentation.messages.enumerated()), id: \.offset) { _, message in
          Text(message)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .frame(width: 320)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(presentation.accessibilityLabel)
  }

  @ViewBuilder
  private var indicator: some View {
    switch presentation.indicator {
    case .recording:
      Image(systemName: "mic.fill")
        .foregroundStyle(.red)
        .symbolEffect(.pulse)
    case .processing:
      ProgressView()
        .controlSize(.small)
    case .failure:
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.yellow)
    case .notice:
      Image(systemName: "info.circle.fill")
        .foregroundStyle(.blue)
    }
  }
}
