import SwiftUI
import UtterCore

/// メニューの「録音を開始」「録音を停止」と「キャンセル」（REC-01, REC-06）
struct SessionMenuItems: View {
  @Environment(AppComposition.self) private var composition

  var body: some View {
    let session = composition.session
    Button(Self.toggleTitle(session.phase)) {
      session.toggle()
    }
    .disabled(!Self.canToggle(session.phase))
    // Esc の捕捉（#149）が入るまで、キャンセルはメニューから行う（REC-01）
    Button("キャンセル") {
      session.cancel()
    }
    .disabled(!session.canCancel)
  }

  private static func toggleTitle(_ phase: SessionPhase) -> String {
    phase == .recording ? "録音を停止" : "録音を開始"
  }

  /// 処理中の開始操作は受け付けない（REC-06）
  private static func canToggle(_ phase: SessionPhase) -> Bool {
    phase == .idle || phase == .recording
  }
}
