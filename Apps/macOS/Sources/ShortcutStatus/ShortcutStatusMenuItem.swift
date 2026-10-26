import SwiftUI
import UtterCore

/// メニューの録音ショートカットの状態と最後の操作（REC-01, REC-02）。
///
/// `Sources/Shortcut` はテスト・バンドル `UtterMacTests` にソースごと含めるため、画面の部品はここに分ける。
struct ShortcutStatusMenuItem: View {
  @Environment(ShortcutCoordinator.self) private var shortcuts

  var body: some View {
    Text(shortcuts.statusText)
    if let command = shortcuts.lastCommand {
      Text("最後の操作: \(Self.commandName(command))")
    }
  }

  private static func commandName(_ command: ShortcutCommand) -> String {
    switch command {
    case .startRecording: "録音開始"
    case .stopRecording: "録音停止"
    case .cancelSession: "キャンセル"
    }
  }
}
