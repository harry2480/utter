import SwiftUI
import UtterCore

/// HUD の中身（REC-03, REC-05, AC-16）。文言は `HUDPresentation` のものをそのまま出す。
///
/// 1行目に状態（録音中は経過時間・レベルメーター、クラウドへ送る間は送信先）を出し、その下に通知・処理の4段階・
/// Realtime Preview の認識テキスト・録音中のチップ・停止とキャンセルのキーを順に出す。
/// Realtime Preview（2.2節, AC-03）の認識テキストは、確定済みは通常の色、暫定は淡い色と点線の下線
/// （かな漢字変換の未確定文字と同じ見せ方）で区別する。長くなったら新しい側を残して先頭を省く。
/// 要素のラベルは `accessibilityLabel` だけで、認識テキストを VoiceOver に読ませない（録音中の読み上げがマイクに入るため）。
struct HUDView: View {
  /// 認識テキストの最大行数（仮置き。HUD の幅 320pt で、入力先の画面を大きく覆わない程度）
  private static let transcriptLineLimit = 3
  /// レベルメーターの各バーの高さ（仮置き。左から右へ波形のように並べる）
  private static let levelBarHeights: [CGFloat] = [6, 14, 10, 16, 8]

  let presentation: HUDPresentation

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      header
      if !presentation.messages.isEmpty {
        // 録音停止（または失敗の理由）と整形の退避の通知が重なると複数行になる（REC-05, AC-16）
        VStack(alignment: .leading, spacing: 2) {
          ForEach(Array(presentation.messages.enumerated()), id: \.offset) { _, message in
            Text(message)
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
      if let stage = presentation.stage {
        stageProgress(current: stage)
      }
      if let transcript = presentation.transcript {
        transcriptText(transcript)
          .font(.body)
          .lineLimit(Self.transcriptLineLimit)
          .truncationMode(.head)
          .fixedSize(horizontal: false, vertical: true)
      }
      if !presentation.chips.isEmpty {
        chipRow
      }
      if !presentation.keyHints.isEmpty {
        keyHintRow
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .frame(width: 320, alignment: .leading)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(presentation.accessibilityLabel)
  }

  /// 状態の行。アイコン・状態・経過時間・送信先・レベルメーター
  private var header: some View {
    HStack(alignment: .center, spacing: 8) {
      indicator
        .frame(width: 18)
        .accessibilityHidden(true)
      Text(presentation.title)
        .font(.headline)
        .fixedSize(horizontal: false, vertical: true)
      if let time = presentation.recordingTimeText {
        Text(time)
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      if let destination = presentation.destination {
        Text(destination)
          .font(.caption)
          .foregroundStyle(.orange)
          .padding(.horizontal, 8)
          .padding(.vertical, 2)
          .background(Color.orange.opacity(0.15), in: Capsule())
      }
      Spacer(minLength: 0)
      if let bars = presentation.inputLevelBars {
        levelMeter(bars: bars)
      }
    }
  }

  /// 処理の4段階（録音 → 認識 → 整形 → 挿入）。終えた段階・今の段階・これからの段階を色で分ける
  private func stageProgress(current: HUDProcessingStage) -> some View {
    let stages = HUDProcessingStage.allCases
    let currentIndex = stages.firstIndex(of: current) ?? 0
    return HStack(spacing: 6) {
      ForEach(Array(stages.enumerated()), id: \.offset) { index, stage in
        VStack(alignment: .leading, spacing: 4) {
          Capsule()
            .fill(stageColor(index: index, currentIndex: currentIndex))
            .frame(height: 3)
          Text(stage.label)
            .font(.caption2)
            .fontWeight(index == currentIndex ? Font.Weight.bold : .regular)
            .foregroundStyle(index == currentIndex ? HierarchicalShapeStyle.primary : .secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  private func stageColor(index: Int, currentIndex: Int) -> Color {
    if index < currentIndex { return .accentColor }
    if index == currentIndex { return .primary }
    return Color.secondary.opacity(0.3)
  }

  /// 録音中のチップ（整形モード・アプリ別スタイル・音声認識の種別）
  private var chipRow: some View {
    HStack(spacing: 6) {
      ForEach(Array(presentation.chips.enumerated()), id: \.offset) { _, chip in
        Text(chip)
          .font(.caption2)
          .lineLimit(1)
          .padding(.horizontal, 8)
          .padding(.vertical, 2)
          .background(Color.secondary.opacity(0.15), in: Capsule())
      }
    }
  }

  /// 停止とキャンセルのキー
  private var keyHintRow: some View {
    HStack(spacing: 12) {
      ForEach(Array(presentation.keyHints.enumerated()), id: \.offset) { _, hint in
        HStack(spacing: 4) {
          Text(hint.key)
            .font(.caption2.monospaced())
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay {
              RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(Color.secondary.opacity(0.6), lineWidth: 1)
            }
          Text(hint.action)
            .font(.caption2)
        }
        .foregroundStyle(.secondary)
      }
    }
  }

  /// レベルメーター。点灯する本数だけを強調する
  private func levelMeter(bars: Int) -> some View {
    HStack(alignment: .bottom, spacing: 2) {
      ForEach(Array(Self.levelBarHeights.enumerated()), id: \.offset) { index, height in
        RoundedRectangle(cornerRadius: 1.5)
          .fill(index < bars ? Color.red : Color.secondary.opacity(0.3))
          .frame(width: 3, height: height)
      }
    }
    .frame(height: 16, alignment: .bottom)
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
    case .completed:
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(.blue)
    }
  }
}
