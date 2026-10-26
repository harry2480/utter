import AppKit
import SwiftUI
import UtterCore
import UtterPersistence

/// macOS アプリの起動部（Composition Root）。
///
/// メニューバーに常駐し、Dock には出さない（Info.plist の `LSUIElement`）。
/// 部品の組み立ては `AppComposition`、セッションの進行は `SessionCoordinator` が持つ。
@main
struct UtterApp: App {
  @State private var composition = AppComposition()
  @State private var consentSettings = ConsentSettingsModel(
    controller: ConsentSettingsController(store: AppSettingsStore(defaults: .standard)))

  var body: some Scene {
    MenuBarExtra("utter", systemImage: "mic") {
      MenuContent(composition: composition)
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
  let composition: AppComposition
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    let session = composition.session
    Text(composition.shortcuts.statusText)
    Divider()
    Button(Self.toggleTitle(session.phase)) {
      session.toggle()
    }
    .disabled(!Self.canToggle(session.phase))
    // Esc の捕捉（#149）が入るまで、キャンセルはメニューから行う（REC-01）
    Button("キャンセル") {
      session.cancel()
    }
    .disabled(!session.canCancel)
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

  private static func toggleTitle(_ phase: SessionPhase) -> String {
    phase == .recording ? "録音を停止" : "録音を開始"
  }

  /// 処理中の開始操作は受け付けない（REC-06）
  private static func canToggle(_ phase: SessionPhase) -> Bool {
    phase == .idle || phase == .recording
  }
}
