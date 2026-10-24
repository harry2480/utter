import AppKit
import SwiftUI
import UtterCore
import UtterPersistence

/// macOS アプリの起動部（Composition Root）。
///
/// メニューバーに常駐し、Dock には出さない（Info.plist の `LSUIElement`）。
/// 部品の組み立ては `AppComposition`、セッションの進行は `SessionCoordinator` が持つ。
/// 整形の予算判定を結線するときは、`CloudCostBridge.makeBudgetGuard` に同じデータベースの `MonthlyUsageStore` を渡す（AI-05）。
@main
struct UtterApp: App {
  @State private var composition = AppComposition()
  @State private var settings = SettingsModel(
    store: AppSettingsStore(defaults: .standard),
    openUsageStore: {
      MonthlyUsageStore(database: try UtterDatabase.open(at: AppDatabaseLocation.url()))
    })

  var body: some Scene {
    MenuBarExtra("utter", systemImage: "mic") {
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
      SettingsMenuButton()
      Divider()
      Button("utter を終了") {
        NSApplication.shared.terminate(nil)
      }
      .keyboardShortcut("q")
    }
    // 設定画面は1つの Settings シーンにまとめ、項目はタブで分ける（API キーなどの画面もタブとして足す）
    Settings {
      SettingsView(model: settings)
    }
  }

  private static func toggleTitle(_ phase: SessionPhase) -> String {
    phase == .recording ? "録音を停止" : "録音を開始"
  }

  /// 処理中の開始操作は受け付けない（REC-06）
  private static func canToggle(_ phase: SessionPhase) -> Bool {
    phase == .idle || phase == .recording
  }
}

/// 設定画面を開くメニュー項目。Dock に出ないアプリでは設定画面が前面に来ないため、先にアプリを前面にする
private struct SettingsMenuButton: View {
  @Environment(\.openSettings) private var openSettings

  var body: some View {
    Button("設定…") {
      NSApplication.shared.activate()
      openSettings()
    }
    .keyboardShortcut(",")
  }
}
