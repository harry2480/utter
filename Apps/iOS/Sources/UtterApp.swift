import Foundation
import SwiftUI
import UtterAI
import UtterPersistence
import UtterSpeech
import UtteriOSKit

/// iOS 本体アプリの起動部（Composition Root）。
///
/// 録音（AVAudioSession / AVAudioEngine）・音声認識・ローカル整形・共有結果の保存を組み立てる。
/// - 音声認識は iOS の STT エンジンの判定（#54）まで `UnconfiguredSpeechRecognizer`（録音のみ・認識しない）。
///   Config/Local.xcconfig の `UTTER_IOS_STT_ENGINE`（Debug は起動引数 `-UtterSpeechEngine`）で `speechAnalyzer` を
///   明示したときだけ SpeechAnalyzer を使い、そのモデルは設定画面の操作でだけ取得する（PERM-03）
/// - 整形は Local Basic。処理系にクラウド AI を選び、Claude への送信に同意し、API キー（本体アプリの Keychain）と月次予算・単価表がそろったときだけ
///   Claude で整形する（iOS-10）。同意・設定は `UserDefaults.standard`（App Group ではない）に保存する
/// - 共有結果と本体アプリの状態（キーボード拡張の案内用, iAC-07）は、App Group（Config/Local.xcconfig）を設定したときだけ
///   App Group に書く（#56）
@main
struct UtterApp: App {
  @State private var model: RecordingSessionModel
  @State private var refinementSettings: RefinementSettingsModel
  @State private var consentSettings: ConsentSettingsModel
  @State private var claudeAPIKeySettings: APIKeySettingsModel
  @State private var speechModel: SpeechModelSettingsModel?
  private let speechEngine: SpeechEngineSelection
  private let hostAppStatus: HostAppStatusPublisher?
  private let signals: RecordingSignalObserver

  init() {
    let speechEngine = Self.speechEngine()
    // 設定画面と本体アプリの状態の書き込みで同じものを使う
    let modelAssets = speechEngine.makeModelAssets()
    let appGroupIdentifier =
      Bundle.main.object(forInfoDictionaryKey: "UtterAppGroupIdentifier") as? String
    let storage = SharedResultStorage.resolve(
      appGroupIdentifier: appGroupIdentifier, appLocalDirectory: Self.appLocalResultsDirectory())
    // 整形と予算・同意の画面とクラウド整形で同じ保存先を使い、変更・撤回を次の送信から反映する（AC-06）
    let settingsStore = AppSettingsStore(defaults: .standard)
    let claudeAPIKeyStore = KeychainAPIKeyStore.claude()
    let databaseURL = Self.databaseURL()
    let cloudRefinement = CloudRefinement(
      settingsStore: settingsStore, apiKeyStore: claudeAPIKeyStore,
      // データベースは最初のクラウド整形のときに、メインスレッドの外で開く
      budgetSource: UsageStoreBudgetSource(
        makeStore: { MonthlyUsageStore(database: try UtterDatabase.open(at: databaseURL)) },
        pendingReservationURL: URL.applicationSupportDirectory.appending(
          path: "PendingCloudRefinementCost.json")))
    let model = RecordingSessionModel(
      recorder: AudioEngineRecorder(
        requestsSpeechRecognitionPermission: speechEngine.requestsSpeechRecognitionPermission),
      recognizer: Self.makeRecognizer(speechEngine), cloudRefinement: cloudRefinement,
      storage: storage, copier: PasteboardCopier())
    _model = State(initialValue: model)
    _speechModel = State(
      initialValue: modelAssets.map { SpeechModelSettingsModel(assets: $0) })
    self.speechEngine = speechEngine
    _refinementSettings = State(
      initialValue: RefinementSettingsModel(
        store: settingsStore,
        // 推定費用の表示のときに、メインスレッドの外で開く
        openUsageStore: { MonthlyUsageStore(database: try UtterDatabase.open(at: databaseURL)) }))
    _consentSettings = State(
      initialValue: ConsentSettingsModel(
        controller: ConsentSettingsController(store: settingsStore)))
    _claudeAPIKeySettings = State(initialValue: APIKeySettingsModel(store: claudeAPIKeyStore))
    hostAppStatus = HostAppStatusPublisher.resolve(
      appGroupIdentifier: appGroupIdentifier, permissions: SystemHostAppPermissionReader(),
      speechEngine: speechEngine, speechModel: modelAssets,
      settingsStore: settingsStore)
    signals = RecordingSignalObserver(model: model)
  }

  var body: some Scene {
    WindowGroup {
      RecordingView(
        model: model, refinementSettings: refinementSettings, consentSettings: consentSettings,
        claudeAPIKeySettings: claudeAPIKeySettings, speechEngine: speechEngine,
        speechModel: speechModel, hostAppStatus: hostAppStatus)
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

  /// 辞書・使用量（推定費用の累計）のデータベース。アプリ内にだけ置き、キーボードとは共有しない
  private static func databaseURL() -> URL {
    URL.applicationSupportDirectory.appending(path: "utter.sqlite")
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
