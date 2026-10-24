import Foundation
import SwiftUI
import UtterSpeech
import UtteriOSKit

/// iOS 本体アプリの起動部（Composition Root）。
///
/// 録音（AVAudioSession / AVAudioEngine）・音声認識・ローカル整形・共有結果の保存を組み立てる。
/// - 音声認識は iOS の STT エンジンの判定（#54）まで `UnconfiguredSpeechRecognizer`（録音のみ・認識しない）
/// - 整形は Local Basic だけ。クラウド整形と認証画面は別の PR で結線する
/// - 共有結果は App Group ID（Config/Local.xcconfig）を設定したときだけ App Group に保存する（#56）
@main
struct UtterApp: App {
  @State private var model: RecordingSessionModel
  private let signals: RecordingSignalObserver

  init() {
    let storage = SharedResultStorage.resolve(
      appGroupIdentifier: Bundle.main.object(forInfoDictionaryKey: "UtterAppGroupIdentifier")
        as? String,
      appLocalDirectory: Self.appLocalResultsDirectory())
    let model = RecordingSessionModel(
      recorder: AudioEngineRecorder(), recognizer: Self.makeRecognizer(), storage: storage,
      copier: PasteboardCopier())
    _model = State(initialValue: model)
    signals = RecordingSignalObserver(model: model)
  }

  var body: some Scene {
    WindowGroup {
      RecordingView(model: model)
    }
  }

  /// App Group を使わないときの共有結果の保存先。端末のバックアップに本文を含めない
  private static func appLocalResultsDirectory() -> URL {
    var directory = URL.applicationSupportDirectory.appending(
      path: "SharedResults", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try? directory.setResourceValues(values)
    return directory
  }

  private static func makeRecognizer() -> any SpeechRecognizer {
    #if DEBUG
      // 開発中に保存・コピーの流れを確かめるため、起動引数 -UtterStubSpeechRecognizer YES で固定の結果を返す
      if UserDefaults.standard.bool(forKey: "UtterStubSpeechRecognizer") {
        return StubSpeechRecognizer(steps: [.confirmed("これはテスト用の認識結果です")])
      }
    #endif
    return UnconfiguredSpeechRecognizer()
  }
}
