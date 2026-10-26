import SwiftUI

/// メニューの録音ショートカットの状態・権限の要求（REC-01, REC-02, PERM-01）。
///
/// `Sources/Shortcut` はテスト・バンドル `UtterMacTests` にソースごと含めるため、画面の部品はここに分ける。
struct ShortcutStatusMenuItem: View {
  @Environment(ShortcutCoordinator.self) private var shortcuts

  var body: some View {
    Text(shortcuts.statusText)
    if let escapeText = shortcuts.escapeStatusText {
      Text(escapeText)
    }
    ForEach(shortcuts.missingPermissions, id: \.self) { permission in
      Button(GlobalShortcutStatusText.requestTitle(for: permission)) {
        shortcuts.requestPermission(permission)
      }
    }
  }
}
