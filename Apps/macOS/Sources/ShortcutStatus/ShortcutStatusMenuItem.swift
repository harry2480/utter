import SwiftUI

/// メニューの録音ショートカットの状態（REC-01, REC-02）。
///
/// `Sources/Shortcut` はテスト・バンドル `UtterMacTests` にソースごと含めるため、画面の部品はここに分ける。
struct ShortcutStatusMenuItem: View {
  @Environment(ShortcutCoordinator.self) private var shortcuts

  var body: some View {
    Text(shortcuts.statusText)
  }
}
