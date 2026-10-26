import AppKit
import SwiftUI

/// メニューバーのメニュー。
///
/// 項目は機能のディレクトリに置き、ここには1機能1行で並べるだけにする。
struct AppMenu: View {
  var body: some View {
    // 機能ごとの項目。1機能1行で、関係する機能の近くに足す
    #if DEBUG
      HUDDemoMenuItem()
      Divider()
    #endif
    ConsentSettingsMenuItem()
    Divider()
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
