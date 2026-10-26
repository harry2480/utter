#if DEBUG
  import SwiftUI

  /// メニューの録音の確認用の項目（REC-04, REC-05）。
  ///
  /// 録音を結線するまでの確認用（Debug ビルドだけ）。モデルは `UtterApp` が持ち、`environment` で渡す。
  struct RecordingCheckMenuItem: View {
    @Environment(RecordingCheck.self) private var recordingCheck

    var body: some View {
      Button(recordingCheck.isRecording ? "録音を止める（確認用）" : "録音を始める（確認用）") {
        Task { await recordingCheck.toggle() }
      }
      Text(recordingCheck.status)
      Divider()
    }
  }
#endif
