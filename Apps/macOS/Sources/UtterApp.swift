import AppKit
import SwiftUI
import UtterCore

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

  var body: some Scene {
    MenuBarExtra("utter", systemImage: "mic") {
      OpenPermissionOnboardingButton()
      Divider()
      Button("utter を終了") {
        NSApplication.shared.terminate(nil)
      }
      .keyboardShortcut("q")
    }

    Window("権限の設定", id: PermissionOnboardingWindow.id) {
      PermissionOnboardingView(model: permissionOnboarding)
    }
    .windowResizability(.contentSize)
    // メニューから開いたときだけ出す。起動時・前回終了時の状態の復元では開かない
    .defaultLaunchBehavior(.suppressed)
    .restorationBehavior(.disabled)
  }
}

private enum PermissionOnboardingWindow {
  static let id = "permission-onboarding"
}

/// メニューから権限オンボーディングの画面を開く。メニューバー常駐のアプリは前面に来ないため、開くときに前面にする
private struct OpenPermissionOnboardingButton: View {
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Button("権限の設定…") {
      openWindow(id: PermissionOnboardingWindow.id)
      NSApplication.shared.activate()
    }
  }
}
