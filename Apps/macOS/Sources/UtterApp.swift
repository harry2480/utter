import AppKit
import SwiftUI
import UtterCore
import UtterPersistence

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
  @State private var consentSettings = ConsentSettingsModel(
    controller: ConsentSettingsController(store: AppSettingsStore(defaults: .standard)))

  var body: some Scene {
    MenuBarExtra("utter", systemImage: "mic") {
      #if DEBUG
        MenuContent(editMode: editMode)
      #else
        MenuContent()
      #endif
    }
    Window("クラウド送信の同意", id: WindowID.consentSettings) {
      ConsentSettingsView(model: consentSettings)
    }
    .windowResizability(.contentMinSize)
  }
}

enum WindowID {
  static let consentSettings = "consentSettings"
}

/// メニューバーのメニュー
private struct MenuContent: View {
  #if DEBUG
    /// Edit Mode の Debug 用の組み立て。`nil` のときは Edit Mode の項目を出さない
    let editMode: EditModeDebugController?
  #endif
  @Environment(\.openWindow) private var openWindow

  var body: some View {
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
    Button("クラウド送信の同意…") {
      openWindow(id: WindowID.consentSettings)
      // Dock に出ないアプリのため、開いた画面を前面に出す
      NSApplication.shared.activate()
    }
    Divider()
    Button("utter を終了") {
      NSApplication.shared.terminate(nil)
    }
    .keyboardShortcut("q")
  }
}
