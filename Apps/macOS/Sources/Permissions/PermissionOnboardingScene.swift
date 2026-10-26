import SwiftUI

/// 権限の設定の画面（PERM-01, PERM-02）。
struct PermissionOnboardingScene: Scene {
  static let windowID = "permission-onboarding"

  @State private var model: PermissionOnboardingModel = {
    let defaults = PermissionDefaults()
    return PermissionOnboardingModel(
      configuration: .phase0Pending, access: SystemPermissionAccess(defaults: defaults),
      defaults: defaults)
  }()

  var body: some Scene {
    Window("権限の設定", id: Self.windowID) {
      PermissionOnboardingView(model: model)
    }
    .windowResizability(.contentSize)
    // メニューから開いたときだけ出す。起動時・前回終了時の状態の復元では開かない
    .defaultLaunchBehavior(.suppressed)
    .restorationBehavior(.disabled)
  }
}

/// メニューの「権限の設定…」
struct PermissionOnboardingMenuItem: View {
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Button("権限の設定…") {
      openWindow(id: PermissionOnboardingScene.windowID)
      bringToFront()
    }
  }
}
