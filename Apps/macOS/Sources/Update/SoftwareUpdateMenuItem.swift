import SwiftUI

/// メニューの自動更新の項目。Sparkle が起動していない（設定がそろっていない）ときは出さない
struct SoftwareUpdateMenuItem: View {
  @Environment(SoftwareUpdater.self) private var updater

  var body: some View {
    if updater.isAvailable {
      Button("アップデートを確認…") {
        updater.checkForUpdates()
      }
      .disabled(!updater.canCheckForUpdates)
      Toggle(
        "アップデートを自動で確認",
        isOn: Binding(
          get: { updater.automaticallyChecksForUpdates },
          set: { updater.setAutomaticallyChecksForUpdates($0) }))
      Divider()
    }
  }
}
