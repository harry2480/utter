import SwiftUI
import UtterCore

/// メニューの「録音を開始」「録音を停止」と「キャンセル」（REC-01, REC-06）。
/// Realtime Direct（AC-15）で書き込んだ直後だけ、書き込んだテキストを取り除く項目を出す
struct SessionMenuItems: View {
  @Environment(AppComposition.self) private var composition

  var body: some View {
    let session = composition.session
    Button(Self.toggleTitle(session.phase)) {
      session.toggle()
    }
    .disabled(!Self.canToggle(session.phase))
    // Esc の捕捉は #51 の判定まで既定で無効のため、キャンセルはメニューからも行える（REC-01）
    Button("キャンセル") {
      session.cancel()
    }
    .disabled(!session.canCancel)
    if session.canUndoRealtimeDirect {
      Button("Realtime Direct の入力を取り消す") {
        session.undoRealtimeDirect()
      }
    }
  }

  private static func toggleTitle(_ phase: SessionPhase) -> String {
    phase == .recording ? "録音を停止" : "録音を開始"
  }

  /// 処理中の開始操作は受け付けない（REC-06）
  private static func canToggle(_ phase: SessionPhase) -> Bool {
    phase == .idle || phase == .recording
  }
}
