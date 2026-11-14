import AppKit
import SwiftUI

/// メニューバーのメニュー（ウインドウ形式）。
///
/// 上に今の状態と録音ショートカット、中に入力モード・文体・整形の実行先・認識モデルと費用、
/// 下に設定などの操作を並べる。項目は機能のディレクトリに置き、ここには1機能1行で並べるだけにする。
struct AppMenu: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      // 状態と録音の操作。1機能1行で、関係する機能の近くに足す
      VStack(alignment: .leading, spacing: 4) {
        SessionStatusMenuItem()
          .font(.headline)
        ShortcutStatusMenuItem()
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      SessionMenuItems()
      Divider()
      MenuBarSwitchItems()
      Divider()
      VStack(alignment: .leading, spacing: 2) {
        EditModeMenuItems()
        PermissionOnboardingMenuItem()
        SettingsMenuItem()
        DictionaryEditorMenuItem()
        InputHistoryMenuItem()
        ConsentSettingsMenuItem()
        SoftwareUpdateMenuItem()
        QuitMenuItem()
      }
      .buttonStyle(MenuRowButtonStyle())
    }
    .padding(16)
    .frame(width: 340)
    .tint(UtterTheme.accent)
  }
}

/// メニュー下部の操作の行。幅いっぱいを押せる
private struct MenuRowButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
      .padding(.horizontal, 6)
      .background(
        configuration.isPressed ? Color.primary.opacity(0.1) : Color.clear,
        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
      )
      .contentShape(Rectangle())
  }
}

/// 機能の画面を開いた後に呼ぶ。Dock に出ないアプリのため、開いた画面を前面に出す
@MainActor
func bringToFront() {
  NSApplication.shared.activate()
}

/// アプリの終了
private struct QuitMenuItem: View {
  var body: some View {
    Button("utter を終了") {
      NSApplication.shared.terminate(nil)
    }
    .keyboardShortcut("q")
  }
}
