import SwiftUI
import UtterAI

/// Claude API キーの設定画面（AC-12）。アプリの設定（`Settings` シーン、メニューの「設定…」）として開く。
struct ClaudeAPIKeySettingsScene: Scene {
  @State private var model: APIKeySettingsModel

  /// - Parameter store: キーの保存先。Claude 整形の `ClaudeProvider(apiKeyStore:)` と同じものを渡す
  init(store: any APIKeyStore) {
    _model = State(initialValue: APIKeySettingsModel(store: store))
  }

  var body: some Scene {
    Settings {
      ClaudeAPIKeySettingsView(model: model)
    }
  }
}

/// メニューの「設定…」
struct ClaudeAPIKeySettingsMenuItem: View {
  @Environment(\.openSettings) private var openSettings

  var body: some View {
    Button("設定…") {
      // Dock に出ないアプリでは開いた画面が前面に来ないため、先にアプリを前面に出す
      bringToFront()
      openSettings()
    }
    .keyboardShortcut(",")
  }
}
