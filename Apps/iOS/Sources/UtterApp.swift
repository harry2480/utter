import Foundation
import SwiftUI
import UtterSpeech
import UtteriOSKit

/// iOS 本体アプリの起動部（Composition Root）。
///
/// 録音（AVAudioSession / AVAudioEngine）・音声認識・ローカル整形・共有結果の保存を組み立てる。
/// - 音声認識は iOS の STT エンジンの判定（#54）まで `UnconfiguredSpeechRecognizer`（録音のみ・認識しない）。
///   Config/Local.xcconfig の `UTTER_IOS_STT_ENGINE`（Debug は起動引数 `-UtterSpeechEngine`）で `speechAnalyzer` を
///   明示したときだけ SpeechAnalyzer を使い、そのモデルは設定画面の操作でだけ取得する（PERM-03）
/// - 整形は Local Basic だけ。クラウド整形と認証画面は別の PR で結線する
/// - 共有結果は App Group ID（Config/Local.xcconfig）を設定したときだけ App Group に保存する（#56）
@main
struct UtterApp: App {
  @State private var model: RecordingSessionModel
  @State private var speechModel: SpeechModelSettingsModel?
  private let speechEngine: SpeechEngineSelection
  private let signals: RecordingSignalObserver

  init() {
    let speechEngine = Self.speechEngine()
    let storage = SharedResultStorage.resolve(
      appGroupIdentifier: Bundle.main.object(forInfoDictionaryKey: "UtterAppGroupIdentifier")
        as? String,
      appLocalDirectory: Self.appLocalResultsDirectory())
    let model = RecordingSessionModel(
      recorder: AudioEngineRecorder(
        requestsSpeechRecognitionPermission: speechEngine.requestsSpeechRecognitionPermission),
      recognizer: Self.makeRecognizer(speechEngine), storage: storage, copier: PasteboardCopier())
    _model = State(initialValue: model)
    _speechModel = State(
      initialValue: speechEngine.makeModelAssets().map { SpeechModelSettingsModel(assets: $0) })
    self.speechEngine = speechEngine
    signals = RecordingSignalObserver(model: model)
  }

  var body: some Scene {
    WindowGroup {
      RecordingView(model: model, speechEngine: speechEngine, speechModel: speechModel)
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

  /// STT エンジンの選択。既定は未設定（#54 の判定待ち）
  private static func speechEngine() -> SpeechEngineSelection {
    var launchArgument: String?
    #if DEBUG
      // 開発中に実機で試すため、起動引数 -UtterSpeechEngine speechAnalyzer でビルド設定を上書きできる
      launchArgument = UserDefaults.standard.string(forKey: "UtterSpeechEngine")
    #endif
    return SpeechEngineSelection.resolve(
      buildSetting: Bundle.main.object(forInfoDictionaryKey: "UtterSpeechEngine") as? String,
      launchArgument: launchArgument)
  }

  private static func makeRecognizer(_ engine: SpeechEngineSelection) -> any SpeechRecognizer {
    #if DEBUG
      // 開発中に保存・コピーの流れを確かめるため、起動引数 -UtterStubSpeechRecognizer YES で固定の結果を返す
      if UserDefaults.standard.bool(forKey: "UtterStubSpeechRecognizer") {
        return StubSpeechRecognizer(steps: [.confirmed("これはテスト用の認識結果です")])
      }
    #endif
    return engine.makeRecognizer()
  }
}
