import AppKit
import SwiftUI
import UtterCore

/// macOS アプリの起動部（Composition Root）。
///
/// メニューバーに常駐し、Dock には出さない（Info.plist の `LSUIElement`）。
/// 録音・ホットキー・HUD・挿入は Phase 0 の判定後に、ここで本番実装と Stub を組み立てて結線する。
@main
struct UtterApp: App {
  #if DEBUG
    @State private var recordingCheck = RecordingCheck(recorder: AVAudioEngineRecorder())
  #endif

  var body: some Scene {
    MenuBarExtra("utter", systemImage: "mic") {
      #if DEBUG
        // 録音を結線するまでの確認用（Debug ビルドだけ）
        Button(recordingCheck.isRecording ? "録音を止める（確認用）" : "録音を始める（確認用）") {
          Task { await recordingCheck.toggle() }
        }
        Text(recordingCheck.status)
        Divider()
      #endif
      Button("utter を終了") {
        NSApplication.shared.terminate(nil)
      }
      .keyboardShortcut("q")
    }
  }
}
