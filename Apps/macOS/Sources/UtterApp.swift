import AppKit
import SwiftUI
import UtterCore

/// macOS アプリの起動部（Composition Root）。
///
/// メニューバーに常駐し、Dock には出さない（Info.plist の `LSUIElement`）。
/// 録音・ホットキー・HUD・挿入は Phase 0 の判定後に、ここで本番実装と Stub を組み立てて結線する。
@main
struct UtterApp: App {
  #if DEBUG
    /// Edit Mode（AC-14, v1.1）の Debug 用の組み立て。`EditModeFeature` で有効にしない限り作らず、メニューにも出さない
    @State private var editMode: EditModeDebugController? =
      EditModeFeature.isEnabled() ? EditModeDebugController.make() : nil
  #endif

  var body: some Scene {
    MenuBarExtra("utter", systemImage: "mic") {
      #if DEBUG
        if let editMode {
          Button("選択範囲を指示で編集（実験・Debug）") {
            editMode.start()
          }
          Button("直前の Edit を元に戻す（実験・Debug）") {
            Task { await editMode.undo() }
          }
          Divider()
        }
      #endif
      Button("utter を終了") {
        NSApplication.shared.terminate(nil)
      }
      .keyboardShortcut("q")
    }
  }
}
