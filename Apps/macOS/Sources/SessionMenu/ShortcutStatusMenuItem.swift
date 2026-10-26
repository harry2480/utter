import SwiftUI

/// メニューの先頭に出す、録音ショートカットの状態（REC-01, REC-02）
struct ShortcutStatusMenuItem: View {
  @Environment(AppComposition.self) private var composition

  var body: some View {
    Text(composition.shortcuts.statusText)
  }
}
