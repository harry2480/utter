import Foundation
import Testing
import UtterAI
import UtterCore
import UtterPersistence
import UtterSpeech

/// 録音のセッションのクラウド STT の結線（4章, AC-06, AI-04, #188）。
/// ローカルのエンジンは `ScriptedSpeechRecognizer`、OpenAI への送信は数えるだけの送信部に置き換え、ネットワークに出ない。
@MainActor
struct SessionCloudSpeechRecognitionTests {
  let clock = ManualClock()
  let presenter = StubHUDPresenter()
  let hudScheduler = StubScheduler()
  let inserter = StubSessionInserter()
  let retention = StubAudioRetention()
  let local = ScriptedSpeechRecognizer()
  let transport = CountingStreamingTransport()
  let hud: HUDController
  private let suite: TestDefaults
  private let database: UtterDatabase

  init() throws {
    suite = try TestDefaults()
    database = try UtterDatabase.inMemory()
    let clock = clock
    hud = HUDController(presenter: presenter, scheduler: hudScheduler, now: { clock.now })
  }

  private var store: AppSettingsStore { AppSettingsStore(defaults: suite.defaults) }

  private func coordinator(
    _ settings: AppSettings,
    recorder: StubAudioRecorder,
    apiKeyStore: StubAPIKeyStore = CloudSpeechRecognitionSettings.apiKeyStore(),
    recovery: (any SessionRecognitionRecovering)? = nil
  ) throws -> SessionCoordinator {
    try store.save(settings)
    let clock = clock
    let database = database
    return SessionCoordinator(
      recorder: recorder,
      recognizer: local,
      refiner: StubSessionRefiner(),
      inserter: inserter,
      hud: hud,
      deadlineScheduler: StubScheduler(),
      audioRetention: retention,
      recognitionRecovery: recovery,
      cloudRecognition: CloudSpeechRecognitionSettings.pipeline(
        store: store, apiKeyStore: apiKeyStore, database: database, transport: transport),
      now: { clock.now })
  }

  @Test("4章, #188: 既定（クラウド STT を選んでいない）ではローカルのエンジンで認識し、音声を送らない")
  func usesLocalEngineByDefault() async throws {
    let recorder = StubAudioRecorder()
    var settings = CloudSpeechRecognitionSettings.ready()
    settings.cloudSpeechRecognitionEnabled = false
    let session = try coordinator(settings, recorder: recorder)

    session.toggle()
    #expect(await eventually { local.runCount == 1 && recorder.isRecording })
    recorder.feed([Float](repeating: 0.1, count: 1_600))
    session.toggle()
    local.send(.completed("ローカルの結果"), to: 0)
    #expect(await eventually { session.phase == .idle })

    #expect(inserter.inserted.map(\.text) == ["ローカルの結果"])
    #expect(transport.count == 0)
  }

  @Test("4章, AC-06: クラウド STT を選び条件がそろえば、STT Worker を通さずに OpenAI で認識して挿入する")
  func recognizesWithCloud() async throws {
    let recorder = StubAudioRecorder()
    // 異常終了の再処理を尋ねられても使わない（クラウド STT のセッションでは Worker の再処理を使わない）
    let recovery = StubRecognitionRecovery(answer: true)
    let session = try coordinator(
      CloudSpeechRecognitionSettings.ready(), recorder: recorder, recovery: recovery)

    session.toggle()
    #expect(await eventually { recorder.isRecording })
    recorder.feed([Float](repeating: 0.1, count: 1_600))
    session.toggle()
    #expect(await eventually { session.phase == .idle })

    #expect(inserter.inserted.map(\.text) == ["明日の会議は10時からです"])
    #expect(transport.count == 1)
    #expect(local.runCount == 0)
    #expect(recovery.questions.isEmpty)
  }

  @Test("7章, AC-12: 録音中に入力先が機密入力になったら、録音した音声を OpenAI へ送らずに理由を表示する")
  func doesNotSendWhenInputBecomesSensitive() async throws {
    let recorder = StubAudioRecorder()
    let session = try coordinator(CloudSpeechRecognitionSettings.ready(), recorder: recorder)

    session.toggle()
    #expect(await eventually { recorder.isRecording })
    recorder.feed([Float](repeating: 0.1, count: 1_600))
    inserter.sensitiveContext = SensitiveInputContext(
      secureField: .on, secureEventInput: .off, app: "com.example.editor")
    session.toggle()
    #expect(await eventually { session.phase == .error(.recognition) })

    #expect(transport.count == 0)
    #expect(
      presenter.current?.message == "入力先が機密入力のため、クラウドで音声認識できませんでした")
    #expect(inserter.inserted.isEmpty)
    #expect(local.runCount == 0)
  }

  @Test("7章, AC-12: 開始時の入力先が機密入力なら、クラウド STT の準備もマイクもせずに録音しない")
  func suppressedStartSkipsCloudPreparation() async throws {
    inserter.sensitiveContext = SensitiveInputContext(
      secureField: .off, secureEventInput: .on, app: "com.example.editor")
    let microphone = StubMicrophoneAccess(authorization: .notDetermined)
    let recorder = StubAudioRecorder(microphone: microphone)
    // 準備に進むと、未保存の API キーの理由が出る
    let session = try coordinator(
      CloudSpeechRecognitionSettings.ready(), recorder: recorder, apiKeyStore: StubAPIKeyStore())

    session.toggle()
    await Task.yield()

    #expect(session.phase == .idle)
    #expect(presenter.current?.title == "セキュア入力が有効なため、録音しません")
    #expect(microphone.requestCount == 0)
    #expect(transport.count == 0)
    #expect(retention.events.isEmpty)
  }

  @Test("AC-06: 音声の送信に同意していなければ、マイクを開かず、ローカルにも切り替えずに理由を表示する")
  func showsReasonWithoutConsent() async throws {
    var settings = CloudSpeechRecognitionSettings.ready()
    settings.consentState = ConsentState()
    let microphone = StubMicrophoneAccess(authorization: .notDetermined)
    let recorder = StubAudioRecorder(microphone: microphone)
    let session = try coordinator(settings, recorder: recorder)

    session.toggle()
    #expect(await eventually { session.phase == .error(.recognition) })

    #expect(presenter.current?.title == "認識に失敗しました")
    #expect(
      presenter.current?.message
        == "クラウド音声認識への音声の送信に同意していないため、クラウドで音声認識できませんでした")
    #expect(microphone.requestCount == 0)
    #expect(!recorder.isRecording)
    #expect(transport.count == 0)
    #expect(local.runCount == 0)
    #expect(inserter.inserted.isEmpty)
  }

  @Test("AC-12: OpenAI API キーが保存されていなければ、マイクを開かずに理由を表示する")
  func showsReasonWithoutAPIKey() async throws {
    let microphone = StubMicrophoneAccess(authorization: .notDetermined)
    let recorder = StubAudioRecorder(microphone: microphone)
    let session = try coordinator(
      CloudSpeechRecognitionSettings.ready(), recorder: recorder, apiKeyStore: StubAPIKeyStore())

    session.toggle()
    #expect(await eventually { session.phase == .error(.recognition) })

    #expect(
      presenter.current?.message == "OpenAI API キーが保存されていないため、クラウドで音声認識できませんでした")
    #expect(microphone.requestCount == 0)
    #expect(transport.count == 0)
  }

  @Test("AI-04: 見込み費用が予算を超えるなら送らず、認識の失敗と理由を表示する")
  func showsReasonWhenBudgetExceeded() async throws {
    let recorder = StubAudioRecorder()
    let session = try coordinator(
      CloudSpeechRecognitionSettings.ready(budgetLimit: 10, inputPrice: 1_000_000),
      recorder: recorder)

    session.toggle()
    #expect(await eventually { recorder.isRecording })
    recorder.feed([Float](repeating: 0.1, count: 1_600))
    session.toggle()
    #expect(await eventually { session.phase == .error(.recognition) })

    #expect(presenter.current?.message == "月次予算の上限を超えるため、クラウドで音声認識できませんでした")
    #expect(transport.count == 0)
    #expect(inserter.inserted.isEmpty)
  }

  @Test("4章, #188: クラウド STT の選択の変更は、録音中のセッションを変えず次のセッションから使う")
  func selectionChangeAppliesToNextSession() async throws {
    let recorder = StubAudioRecorder()
    var localSettings = CloudSpeechRecognitionSettings.ready()
    localSettings.cloudSpeechRecognitionEnabled = false
    let session = try coordinator(localSettings, recorder: recorder)

    session.toggle()
    #expect(await eventually { local.runCount == 1 && recorder.isRecording })
    // 録音中にクラウド STT を選んでも、このセッションはローカルのエンジンのまま
    try store.save(CloudSpeechRecognitionSettings.ready())
    recorder.feed([Float](repeating: 0.1, count: 1_600))
    session.toggle()
    local.send(.completed("ローカルの結果"), to: 0)
    #expect(await eventually { session.phase == .idle })
    #expect(transport.count == 0)

    // 次のセッションからクラウド STT を使う
    session.toggle()
    #expect(await eventually { recorder.isRecording })
    recorder.feed([Float](repeating: 0.1, count: 1_600))
    session.toggle()
    #expect(await eventually { session.phase == .idle })

    #expect(inserter.inserted.map(\.text) == ["ローカルの結果", "明日の会議は10時からです"])
    #expect(transport.count == 1)
    #expect(local.runCount == 1)
  }
}
