import Testing
import UtterAI
import UtterCore
import UtterPersistence
import UtterSpeech
import UtterText

/// クラウド STT を選んだ状態。認識はテストのイベントで進める（送信しない）
@MainActor
private final class SelectedCloudRecognition: SessionCloudSpeechRecognizing {
  private let recognizer: any SpeechRecognizer

  init(recognizer: any SpeechRecognizer) {
    self.recognizer = recognizer
  }

  var isSelected: Bool { true }

  func prepareRecognizer(
    sensitivity: @escaping @Sendable () async -> SensitiveInputDecision
  ) async -> CloudSpeechRecognitionPreparation {
    .ready(recognizer)
  }
}

/// セッションの調停が出す性能計測の区間（6章, #52）。計測器は記録するだけの Stub、録音・認識・挿入・HUD も Stub に置き換える。
@MainActor
struct SessionPerfIntervalTests {
  private static let fieldID = InsertionTargetID(rawValue: "field")
  private static let app = "com.example.editor"

  let clock = ManualClock()
  let presenter = StubHUDPresenter()
  let inserter = StubSessionInserter()
  let recorder = StubAudioRecorder()
  let recognizer = ScriptedSpeechRecognizer()
  let refiner = StubSessionRefiner()
  let measurer = RecordingPerfIntervals()
  let hud: HUDController
  private let suite: TestDefaults

  init() throws {
    suite = try TestDefaults()
    let clock = clock
    hud = HUDController(presenter: presenter, scheduler: StubScheduler(), now: { clock.now })
  }

  private func coordinator(
    inputMode: SessionInputMode = .instant,
    refiner: (any SessionRefining)? = nil,
    cloudRecognition: (any SessionCloudSpeechRecognizing)? = nil,
    realtimeDirect: (any SessionRealtimeDirectWriting)? = nil
  ) -> SessionCoordinator {
    let clock = clock
    return SessionCoordinator(
      recorder: recorder,
      recognizer: recognizer,
      refiner: refiner ?? self.refiner,
      inputMode: inputMode,
      inserter: inserter,
      hud: hud,
      deadlineScheduler: StubScheduler(),
      cloudRecognition: cloudRecognition,
      realtimeDirect: realtimeDirect,
      measurer: measurer,
      now: { clock.now })
  }

  /// 録音を始め、最初の音声チャンクを受け取るまで進める
  private func startAndFeed(_ session: SessionCoordinator) async {
    session.toggle()
    #expect(await eventually { recognizer.runCount == 1 && recorder.isRecording })
    recorder.feed([Float](repeating: 0.1, count: 1_600))
    #expect(await eventually { measurer.ended.contains(.recordingStart) })
  }

  /// 停止して認識を完了させ、待機へ戻るまで進める
  private func stopAndComplete(_ session: SessionCoordinator, text: String = "こんにちは") async {
    session.toggle()
    #expect(session.phase == .recognizing)
    recognizer.send(.completed(text), to: 0)
    #expect(await eventually { session.phase == .idle })
  }

  // MARK: 主要経路

  @Test("6章: ローカル高速入力は録音開始 → 最初の音声、停止 → 確定・挿入・停止→挿入の順に区間を開いて閉じる")
  func localSessionIntervals() async {
    let session = coordinator()

    session.toggle()
    // 録音開始の操作を受けた時点で、入力対象を記録する前に始める
    #expect(measurer.events == [.begin(.recordingStart)])
    #expect(inserter.recordCount == 1)
    #expect(await eventually { recognizer.runCount == 1 && recorder.isRecording })
    // 音声が届くまでは閉じない
    #expect(measurer.openIntervals == [.recordingStart])
    recorder.feed([Float](repeating: 0.1, count: 1_600))
    #expect(await eventually { measurer.ended.contains(.recordingStart) })

    session.toggle()
    // 停止の操作の時点で、確定と停止→挿入を始める
    #expect(measurer.openIntervals == [.sttFinalize, .stopToInsertLocal])
    recognizer.send(.completed("こんにちは"), to: 0)
    #expect(await eventually { session.phase == .idle })

    #expect(
      measurer.events == [
        .begin(.recordingStart), .end(.recordingStart), .begin(.sttFinalize),
        .begin(.stopToInsertLocal), .end(.sttFinalize), .begin(.insert), .end(.insert),
        .end(.stopToInsertLocal),
      ])
    #expect(measurer.openIntervals.isEmpty)
    #expect(measurer.duplicateEnds == 0)
    #expect(inserter.inserted.map(\.text) == ["こんにちは"])
  }

  @Test("6章: クラウド整形を選んでいれば、停止→挿入を AI 整形ありの区間で測る")
  func aiSessionUsesAIInterval() async {
    refiner.selectsCloudRefinement = true
    let session = coordinator()

    await startAndFeed(session)
    await stopAndComplete(session)

    #expect(measurer.begun.contains(.stopToInsertAI))
    #expect(!measurer.begun.contains(.stopToInsertLocal))
    #expect(measurer.ended.suffix(2) == [.insert, .stopToInsertAI])
    #expect(measurer.openIntervals.isEmpty)
  }

  @Test("6章: クラウド整形の送信を LLMComplete で測り、確定の後・挿入の前に閉じる")
  func cloudRefinementMeasuresLLM() async throws {
    let store = AppSettingsStore(defaults: suite.defaults)
    try store.save(RefinementSettings.ready())
    let database = try UtterDatabase.inMemory()
    let transport = CountingTransport()
    let pipeline = SessionRefinementPipeline(
      settingsStore: store, apiKeyStore: RefinementSettings.apiKeyStore(),
      database: { database },
      makeProvider: { configuration, keys in
        ClaudeProvider(apiKeyStore: keys, configuration: configuration, transport: transport)
      },
      now: { RefinementSettings.now }, calendar: RefinementSettings.calendar,
      measurer: measurer)
    let session = coordinator(refiner: pipeline)

    await startAndFeed(session)
    await stopAndComplete(session, text: "えーと明日の会議は10時からです")

    #expect(transport.count == 1)
    #expect(
      measurer.events == [
        .begin(.recordingStart), .end(.recordingStart), .begin(.sttFinalize),
        .begin(.stopToInsertAI), .end(.sttFinalize), .begin(.llmComplete), .end(.llmComplete),
        .begin(.insert), .end(.insert), .end(.stopToInsertAI),
      ])
    #expect(measurer.openIntervals.isEmpty)
  }

  @Test("6章: Realtime Preview は録音開始と同時に初回文字表示の区間を始め、最初の認識テキストで閉じる")
  func realtimePreviewFirstText() async {
    let session = coordinator(inputMode: .realtimePreview)

    session.toggle()
    #expect(measurer.events == [.begin(.recordingStart), .begin(.realtimeFirstText)])
    #expect(await eventually { recognizer.runCount == 1 && recorder.isRecording })
    recorder.feed([Float](repeating: 0.1, count: 1_600))
    #expect(await eventually { measurer.ended.contains(.recordingStart) })
    // 空の暫定結果では閉じない
    recognizer.send(.partial(""), to: 0)
    recognizer.send(.partial("きょうは"), to: 0)
    #expect(await eventually { measurer.ended.contains(.realtimeFirstText) })
    recognizer.send(.partial("きょうはいい"), to: 0)

    await stopAndComplete(session)

    #expect(measurer.begun.filter { $0 == .realtimeFirstText }.count == 1)
    #expect(measurer.ended.filter { $0 == .realtimeFirstText }.count == 1)
    #expect(measurer.openIntervals.isEmpty)
  }

  @Test("6章: Instant では初回文字表示の区間を始めない")
  func instantHasNoFirstTextInterval() async {
    let session = coordinator()

    await startAndFeed(session)
    recognizer.send(.partial("きょうは"), to: 0)
    await stopAndComplete(session)

    #expect(!measurer.begun.contains(.realtimeFirstText))
  }

  // MARK: キャンセル・失敗

  @Test("#52: 音声が届く前にキャンセルしたら、開いている区間をその時点で閉じる")
  func cancelBeforeAudioClosesIntervals() async {
    let session = coordinator(inputMode: .realtimePreview)

    session.toggle()
    #expect(await eventually { recognizer.runCount == 1 && recorder.isRecording })
    session.cancel()

    #expect(session.phase == .idle)
    #expect(
      measurer.events == [
        .begin(.recordingStart), .begin(.realtimeFirstText), .end(.recordingStart),
        .end(.realtimeFirstText),
      ])
    // キャンセルの後に届いた音声で、閉じた区間を閉じ直さない
    recorder.feed([Float](repeating: 0.1, count: 1_600))
    #expect(measurer.duplicateEnds == 0)
  }

  @Test("#52: 認識中にキャンセルしたら、確定と停止→挿入の区間を閉じ、挿入の区間は始めない")
  func cancelWhileRecognizingClosesIntervals() async {
    let session = coordinator()

    await startAndFeed(session)
    session.toggle()
    #expect(measurer.openIntervals == [.sttFinalize, .stopToInsertLocal])
    session.cancel()

    #expect(session.phase == .idle)
    #expect(measurer.openIntervals.isEmpty)
    #expect(!measurer.begun.contains(.insert))
    // キャンセルの後に届いた認識の結果では、区間を始めない
    recognizer.send(.completed("こんにちは"), to: 0)
    #expect(await eventually { recognizer.isTerminated(0) })
    #expect(!measurer.begun.contains(.insert))
    #expect(measurer.duplicateEnds == 0)
  }

  @Test("#52: 認識が失敗したら、失敗の表示に進んだ時点で開いている区間をすべて閉じる")
  func failureClosesIntervals() async {
    let session = coordinator()

    await startAndFeed(session)
    session.toggle()
    recognizer.send(.failed(.engineFailed), to: 0)
    #expect(await eventually { session.phase == .error(.recognition) })

    #expect(measurer.openIntervals.isEmpty)
    #expect(!measurer.begun.contains(.insert))
    #expect(measurer.duplicateEnds == 0)
  }

  @Test("#52: 録音中に認識が失敗しても、停止からの区間を閉じて残さない")
  func failureWhileRecordingClosesIntervals() async {
    let session = coordinator()

    await startAndFeed(session)
    recognizer.send(.failed(.engineFailed), to: 0)
    #expect(await eventually { session.phase == .error(.recognition) })

    #expect(measurer.openIntervals.isEmpty)
    #expect(!measurer.begun.contains(.insert))
  }

  @Test("7章, #52: 入力先が機密入力で録音を始めなかったら、録音開始の区間を閉じる")
  func suppressedRecordingClosesInterval() {
    inserter.sensitiveContext = SensitiveInputContext(
      secureField: .on, secureEventInput: .off, app: Self.app)
    let session = coordinator()

    session.toggle()

    #expect(session.phase == .idle)
    #expect(measurer.events == [.begin(.recordingStart), .end(.recordingStart)])
  }

  @Test("#52: 音声認識が設定されていなければ、録音しないため区間を始めない")
  func notConfiguredStartsNoInterval() {
    let session = SessionCoordinator(
      recorder: recorder, recognizer: nil, refiner: refiner, inserter: inserter, hud: hud,
      deadlineScheduler: StubScheduler(), measurer: measurer)

    session.toggle()

    #expect(session.phase == .error(.recognition))
    #expect(measurer.events.isEmpty)
  }

  // MARK: 別経路

  @Test("#52: クラウド STT のセッションは確定・挿入を測り、ローカル高速入力の停止→挿入は測らない")
  func cloudSpeechRecognitionSkipsStopToInsert() async {
    let session = coordinator(cloudRecognition: SelectedCloudRecognition(recognizer: recognizer))

    await startAndFeed(session)
    await stopAndComplete(session)

    #expect(measurer.begun == [.recordingStart, .sttFinalize, .insert])
    #expect(measurer.openIntervals.isEmpty)
  }

  @Test("#52: クラウド STT は録音中に認識テキストを出さないため、Realtime Preview でも初回文字表示の区間を始めない")
  func cloudSpeechRecognitionHasNoFirstTextInterval() async {
    let session = coordinator(
      inputMode: .realtimePreview,
      cloudRecognition: SelectedCloudRecognition(recognizer: recognizer))

    await startAndFeed(session)
    await stopAndComplete(session)

    #expect(!measurer.begun.contains(.realtimeFirstText))
    #expect(measurer.openIntervals.isEmpty)
  }

  @Test("AC-15, #52: Realtime Direct で書き込んだセッションは停止→挿入と挿入を測らず、区間を残さない")
  func realtimeDirectSkipsStopToInsert() async {
    let log = InsertionLog()
    let field = FakeTextField(value: "メモ: ")
    let inspector = StubInspector(
      targets: [FocusedInsertionTarget(id: Self.fieldID, app: Self.app, secureField: .off)],
      recorded: Self.fieldID)
    let writer = RealtimeDirectWriter(
      inspector: inspector,
      field: StubFieldAccess(field: field, target: Self.fieldID, log: log),
      preview: StubPreview(log: log),
      allowlist: RealtimeDirectAllowlist().adding([Self.app]),
      sensitivePolicy: { SensitiveInputPolicy() })
    let session = coordinator(inputMode: .realtimeDirect, realtimeDirect: writer)

    await startAndFeed(session)
    recognizer.send(.confirmed("こんにちは。"), to: 0)
    #expect(await eventually { field.value == "メモ: こんにちは。" })
    await stopAndComplete(session, text: "こんにちは。")

    #expect(field.value == "メモ: こんにちは。")
    #expect(measurer.begun == [.recordingStart, .sttFinalize])
    #expect(measurer.openIntervals.isEmpty)
  }
}
