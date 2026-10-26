import SwiftUI

/// メニューの先頭に出す、録音ショートカットの状態（REC-01, REC-02）
///
/// Esc の捕捉の状態と、足りない権限を利用者の操作で要求する項目もここに並べる。
struct ShortcutStatusMenuItem: View {
  @Environment(AppComposition.self) private var composition

  var body: some View {
    let shortcuts = composition.shortcuts
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
