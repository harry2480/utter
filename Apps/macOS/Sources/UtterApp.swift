import AppKit
import SwiftUI
import UtterCore
import UtterPersistence
import UtterSpeech

/// macOS アプリの起動部（Composition Root）。
///
/// メニューバーに常駐し、Dock には出さない（Info.plist の `LSUIElement`）。
/// 録音・ホットキー・HUD・挿入は Phase 0 の判定後に、ここで本番実装と Stub を組み立てて結線する。
@main
struct UtterApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @State private var consentSettings = ConsentSettingsModel(
    controller: ConsentSettingsController(store: AppSettingsStore(defaults: .standard)))

  var body: some Scene {
    MenuBarExtra("utter", systemImage: "mic") {
      MenuContent()
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
  @Environment(\.openWindow) private var openWindow

  var body: some View {
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
}

/// 起動から終了まで動かすものの組み立て
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  /// STT Worker を使う音声認識。録音・セッションの結線（Phase 1）でここから使う。
  /// エンジンが未選択のあいだは Worker を起動しない
  private var recognizer: STTWorkerSpeechRecognizer?
  /// 端末の状態の監視（6章, AC-11）。録音・認識の有無に関わらず動かす。
  /// Worker への接続先（アプリの Bundle ID）が取れず認識器を作れないときは、送り先がないため監視もしない
  private var resourceMonitoring: DeviceResourceMonitoring?

  func applicationDidFinishLaunching(_ notification: Notification) {
    guard let recognizer = STTWorkerComposition.makeRecognizer() else { return }
    self.recognizer = recognizer
    resourceMonitoring = STTWorkerComposition.makeResourceMonitoring(for: recognizer)
    resourceMonitoring?.start()
  }

  func applicationWillTerminate(_ notification: Notification) {
    resourceMonitoring?.stop()
  }
}
