import SwiftUI
import UtterPersistence

/// クラウド送信の同意の画面（AC-06）。
struct ConsentSettingsScene: Scene {
  static let windowID = "consentSettings"

  @State private var model = ConsentSettingsModel(
    controller: ConsentSettingsController(store: AppSettingsStore(defaults: .standard)))

  var body: some Scene {
    Window("クラウド送信の同意", id: Self.windowID) {
      ConsentSettingsView(model: model)
    }
    .windowResizability(.contentMinSize)
  }
}

/// メニューの「クラウド送信の同意…」
struct ConsentSettingsMenuItem: View {
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Button("クラウド送信の同意…") {
      openWindow(id: ConsentSettingsScene.windowID)
      bringToFront()
    }
  }
}
