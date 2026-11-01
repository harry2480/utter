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

/// UI テスト（UITests/）用。キーボードの中と App Group は UI テストから見えないため、キーボードが書いた位置・
/// 本体アプリの状態・計測の記録を、読み取り用の小さな文字として出す。起動引数 -ProbeUITest YES のときだけ出す。
/// 中身は時刻・区間名・ボタンの位置・案内の文言だけで、発話の本文は入らない。
struct UITestReadout: View {
  var body: some View {
    TimelineView(.periodic(from: .now, by: 0.5)) { _ in
      VStack(alignment: .leading, spacing: 0) {
        readout(VoiceKeyboardPresence.fileName, identifier: "test.presence")
        readout(VoiceStore.hostStateFileName, identifier: "test.host")
        readout(VoiceStore.eventsFileName, identifier: "test.events", lastLines: 300)
      }
    }
  }

  private func readout(_ fileName: String, identifier: String, lastLines: Int? = nil) -> some View {
    var text = "-"
    if let url = try? VoiceStore.directoryURL().appending(path: fileName),
      let content = try? String(contentsOf: url, encoding: .utf8)
    {
      text =
        lastLines.map { content.split(separator: "\n").suffix($0).joined(separator: "\n") }
        ?? content
    }
    return Text("x")
      .font(.system(size: 2))
      .frame(height: 3)
      .accessibilityLabel(text)
      .accessibilityIdentifier(identifier)
  }
}
