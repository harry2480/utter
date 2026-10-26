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
  @State private var permissionOnboarding: PermissionOnboardingModel = {
    let defaults = PermissionDefaults()
    return PermissionOnboardingModel(
      configuration: .phase0Pending, access: SystemPermissionAccess(defaults: defaults),
      defaults: defaults)
  }()
  @State private var consentSettings = ConsentSettingsModel(
    controller: ConsentSettingsController(store: AppSettingsStore(defaults: .standard)))

  var body: some Scene {
    MenuBarExtra("utter", systemImage: "mic") {
      MenuContent()
    }

    Window("権限の設定", id: WindowID.permissionOnboarding) {
      PermissionOnboardingView(model: permissionOnboarding)
    }
    .windowResizability(.contentSize)
    // メニューから開いたときだけ出す。起動時・前回終了時の状態の復元では開かない
    .defaultLaunchBehavior(.suppressed)
    .restorationBehavior(.disabled)

    Window("クラウド送信の同意", id: WindowID.consentSettings) {
      ConsentSettingsView(model: consentSettings)
    }
    .windowResizability(.contentMinSize)
  }
}

enum WindowID {
  static let permissionOnboarding = "permission-onboarding"
  static let consentSettings = "consentSettings"
}

/// メニューバーのメニュー
private struct MenuContent: View {
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Button("権限の設定…") {
      open(WindowID.permissionOnboarding)
    }
    Button("クラウド送信の同意…") {
      open(WindowID.consentSettings)
    }
    Divider()
    Button("utter を終了") {
      NSApplication.shared.terminate(nil)
    }
    .keyboardShortcut("q")
  }

  private func open(_ id: String) {
    openWindow(id: id)
    // Dock に出ないアプリのため、開いた画面を前面に出す
    NSApplication.shared.activate()
  }
}
