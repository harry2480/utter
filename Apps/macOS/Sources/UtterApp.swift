import AppKit
import SwiftUI
import UtterCore
import UtterPersistence

/// macOS アプリの起動部（Composition Root）。
///
/// メニューバーに常駐し、Dock には出さない（Info.plist の `LSUIElement`）。
/// 録音・HUD・挿入は Phase 0 の判定後に、ここで本番実装と Stub を組み立てて結線する。
@main
struct UtterApp: App {
  @State private var shortcuts = ShortcutCoordinator()
  @State private var consentSettings = ConsentSettingsModel(
    controller: ConsentSettingsController(store: AppSettingsStore(defaults: .standard)))

  var body: some Scene {
    MenuBarExtra("utter", systemImage: "mic") {
      MenuContent(shortcuts: shortcuts)
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
  let shortcuts: ShortcutCoordinator
  @Environment(\.openWindow) private var openWindow

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
    if let command = shortcuts.lastCommand {
      Text("最後の操作: \(Self.commandName(command))")
    }
    Divider()
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

  private static func commandName(_ command: ShortcutCommand) -> String {
    switch command {
    case .startRecording: "録音開始"
    case .stopRecording: "録音停止"
    case .cancelSession: "キャンセル"
    }
  }
}
