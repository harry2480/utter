import SwiftUI
import UtterCore
import UtterPersistence

/// クラウド送信の同意の画面（AC-06）。
///
/// 整形の送信に加え、Edit Mode（AC-14）の選択テキストの送信と、クラウド STT（#188）の音声の送信の同意を、
/// 整形とは別の行で同意・撤回できるようにする。
struct ConsentSettingsScene: Scene {
  static let windowID = "consentSettings"

  @State private var model = ConsentSettingsModel(
    controller: ConsentSettingsController(
      store: AppSettingsStore(defaults: .standard),
      additionalScopes: ConsentScreenState.editModeScopes
        + ConsentScreenState.cloudSpeechRecognitionScopes))

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
