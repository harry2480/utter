import AppKit
import UtterSpeech

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
