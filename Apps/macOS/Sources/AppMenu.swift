import AppKit
import SwiftUI

/// メニューバーのメニュー。
///
/// 項目は機能のディレクトリに置き、ここには1機能1行で並べるだけにする。
struct AppMenu: View {
  #if DEBUG
    /// Edit Mode の Debug 用の組み立て。`nil` のときは Edit Mode の項目を出さない
    let editMode: EditModeDebugController?
  #endif

  var body: some View {
    // 機能ごとの項目。1機能1行で、関係する機能の近くに足す
    ShortcutStatusMenuItem()
    Divider()
    SessionMenuItems()
    Divider()
    #if DEBUG
      RealtimeDirectDebugMenuItem()
      EditModeMenuItem(editMode: editMode)
    #endif
    PermissionOnboardingMenuItem()
    SettingsMenuItem()
    DictionaryEditorMenuItem()
    InputHistoryMenuItem()
    ConsentSettingsMenuItem()
    Divider()
    SoftwareUpdateMenuItem()
    QuitMenuItem()
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
