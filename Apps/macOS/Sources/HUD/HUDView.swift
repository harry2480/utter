import SwiftUI
import UtterCore

/// HUD の中身（REC-03, REC-05, AC-16）。文言は `HUDPresentation` のものをそのまま出す。
///
/// Realtime Preview（2.2節, AC-03）の認識テキストは文言の下に出し、確定済みは通常の色、暫定は淡い色と点線の下線
/// （かな漢字変換の未確定文字と同じ見せ方）で区別する。長くなったら新しい側を残して先頭を省く。
/// 要素のラベルは `accessibilityLabel` だけで、認識テキストを VoiceOver に読ませない（録音中の読み上げがマイクに入るため）。
struct HUDView: View {
  /// 認識テキストの最大行数（仮置き。HUD の幅 320pt で、入力先の画面を大きく覆わない程度）
  private static let transcriptLineLimit = 3

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
        if let transcript = presentation.transcript {
          transcriptText(transcript)
            .font(.body)
            .lineLimit(Self.transcriptLineLimit)
            .truncationMode(.head)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 4)
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

  /// 確定済みと暫定を1つの文として続けて描画する。`Text(String)` は文字列をそのまま出す（ローカライズの対象にしない）
  private func transcriptText(_ transcript: HUDTranscript) -> Text {
    let confirmed = Text(transcript.confirmedText)
    let provisional = Text(transcript.provisionalText)
      .foregroundStyle(.secondary)
      .underline(pattern: .dot)
    return Text("\(confirmed)\(provisional)")
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
