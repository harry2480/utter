// #233 の待機セッション方式の試作（本体アプリの画面）。本番コードではない。

import SwiftUI

struct VoiceSection: View {
  @Bindable var voice: VoiceSessionController

  var body: some View {
    Section {
      LabeledContent("状態", value: voice.phase.rawValue)
      Picker("待機の方式", selection: $voice.mode) {
        ForEach(VoiceSessionController.StandbyMode.allCases) { Text($0.label).tag($0) }
      }
      .disabled(voice.phase != .off)
      Picker("無操作で終える", selection: $voice.idleTimeoutMinutes) {
        Text("5分").tag(5)
        Text("30分").tag(30)
        Text("終えない").tag(0)
      }
      if voice.phase == .off {
        Button("待機を始める") { Task { await voice.startStandby() } }
      } else {
        Button("待機を終える", role: .destructive) { voice.stopStandby(reason: "利用者が終了") }
      }
      Text(voice.lastTimings).font(.caption.monospaced())
      Button("計測の記録を書き出す") { voice.exportEvents() }
      Button("計測の記録を消す", role: .destructive) { voice.clearEvents() }
      ForEach(voice.lines, id: \.self) { Text($0).font(.caption2.monospaced()) }
    } header: {
      Text("音声入力の待機（#233）")
    } footer: {
      Text(
        "待機を始めてから元のアプリへ戻り、キーボードの🎤で録音を始め、もう一度押して止める。音声は保存しない。"
      )
    }
  }
}
