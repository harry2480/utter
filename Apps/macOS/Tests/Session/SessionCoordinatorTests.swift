import Testing
import UtterAI
import UtterCore
import UtterPersistence
import UtterSpeech

/// 録音 → 認識 → 整形 → 挿入 → HUD の調停（REC-01〜06, INS-01, AC-02, AC-09）。録音・認識・挿入・HUD は Stub に置き換える。
@MainActor
struct SessionCoordinatorTests {
  let clock = ManualClock()
  let presenter = StubHUDPresenter()
  let hudScheduler = StubScheduler()
  let deadlineScheduler = StubScheduler()
  let inserter = StubSessionInserter()
  let retention = StubAudioRetention()
  let hud: HUDController
  private let suite: TestDefaults

  init() throws {
    suite = try TestDefaults()
    let clock = clock
    hud = HUDController(presenter: presenter, scheduler: hudScheduler, now: { clock.now })
  }

  private func coordinator(
    recorder: StubAudioRecorder = StubAudioRecorder(),
    recognizer: (any SpeechRecognizer)? = StubSpeechRecognizer(steps: [.confirmed("こんにちは")]),
    mode: RefinementMode = .raw,
    configuration: SessionConfiguration = SessionConfiguration(),
    recovery: (any SessionRecognitionRecovering)? = nil
  ) -> SessionCoordinator {
    let clock = clock
    let store = AppSettingsStore(defaults: suite.defaults)
    // 整形は既定の Local Basic（送信しない）で、整形モードだけを変える
    try? store.save(AppSettings(refinementMode: RefinementModeSetting(mode)))
    let database = try? UtterDatabase.inMemory()
    return SessionCoordinator(
      configuration: configuration,
      recorder: recorder,
      recognizer: recognizer,
      refiner: SessionRefinementPipeline(
        settingsStore: store, apiKeyStore: StubAPIKeyStore(),
        database: {
          guard let database else { throw CancellationError() }
          return database
        }),
      inserter: inserter,
      hud: hud,
      deadlineScheduler: deadlineScheduler,
      audioRetention: retention,
      recognitionRecovery: recovery,
      now: { clock.now })
  }

  private var insertedTexts: [String] {
    inserter.inserted.map(\.text)
  }

  // MARK: 成功

  @Test("AC-02: 開始 → 録音 → 停止 → 認識 → 整形（Raw）→ 挿入 → 待機の順に進み、HUD に各段階を出す")
  func completesSession() async throws {
    let recorder = StubAudioRecorder()
    let session = coordinator(recorder: recorder)

    session.toggle()
    #expect(session.phase == .recording)
    #expect(inserter.recordCount == 1)
    #expect(presenter.current?.title == "録音中")
    #expect(await eventually { recorder.isRecording })
    recorder.feed([Float](repeating: 0.1, count: 1_600))

    session.toggle()
    #expect(session.phase == .recognizing)
    #expect(presenter.current?.title == "認識中")
    #expect(await eventually { session.phase == .idle })

    #expect(insertedTexts == ["こんにちは"])
    #expect(inserter.inserted.first?.target == inserter.target)
    #expect(!recorder.isRecording)
    #expect(!presenter.isVisible)
    #expect(presenter.shown.map(\.title) == ["録音中", "認識中", "整形中", "挿入中"])
    let id = try #require(
      retention.events.first.flatMap { event -> SessionID? in
        if case .begin(let id) = event { return id }
        return nil
      })
    // 録音が止まったことを伝えてから（一時音声の保存）、終わりを伝える（削除）
    #expect(retention.events == [.begin(id), .finishRecording(id), .end(id, completed: true)])
    #expect(await eventually { retention.appendedSampleCount == 1_600 })
  }

  @Test("REC-01: 状態が変わるたびに onPhaseChange で知らせる（Esc の捕捉をセッション中だけ有効にするため）")
  func notifiesPhaseChanges() async {
    let recorder = StubAudioRecorder()
    let session = coordinator(recorder: recorder)
    let log = PhaseLog()
    session.onPhaseChange = { [weak session] in
      if let session { log.phases.append(session.phase) }
    }

    session.toggle()
    #expect(await eventually { recorder.isRecording })
    recorder.feed([Float](repeating: 0.1, count: 1_600))
    session.toggle()
    #expect(await eventually { session.phase == .idle })

    #expect(log.phases == [.recording, .recognizing, .refining, .inserting, .idle])
  }

  @Test("AI-03, CTX-01: Local Basic は録音開始時の前面アプリのスタイル区分で整形する")
  func refinesWithLocalBasic() async {
    let text = "えーと、ls -la を実行して"
    inserter.target = RecordedInsertionTarget(
      id: InsertionTargetID(rawValue: "terminal"), app: "com.apple.Terminal")
    let recorder = StubAudioRecorder()
    let session = coordinator(
      recorder: recorder, recognizer: StubSpeechRecognizer(steps: [.confirmed(text)]),
      mode: .natural)

    session.toggle()
    #expect(await eventually { recorder.isRecording })
    session.toggle()
    #expect(await eventually { session.phase == .idle })

    let expected = LocalBasicRefiner().refine(
      RefinementRequest(text: text, mode: .natural, style: .command))
    #expect(insertedTexts == [expected])
  }

  @Test("INS-01, AC-09: 挿入がプレビューへ退避しても、文字列を失わずに完了として待機へ戻る")
  func previewFallbackCompletes() async {
    inserter.outcome = .preview(.plan(.targetChanged))
    let recorder = StubAudioRecorder()
    let session = coordinator(recorder: recorder)

    session.toggle()
    #expect(await eventually { recorder.isRecording })
    session.toggle()
    #expect(await eventually { session.phase == .idle })

    #expect(insertedTexts == ["こんにちは"])
    #expect(
      retention.events.last.map { if case .end(_, let completed) = $0 { completed } else { false } }
        == true)
  }

  // MARK: STT 未設定・失敗

  @Test("11章: 音声認識のエンジンが選ばれていなければマイクを開かず、「音声認識が設定されていません」を表示する")
  func showsNotConfiguredWithoutRecording() {
    let microphone = StubMicrophoneAccess(authorization: .notDetermined)
    let recorder = StubAudioRecorder(microphone: microphone)
    let session = coordinator(recorder: recorder, recognizer: nil)

    session.toggle()

    #expect(session.phase == .error(.recognition))
    #expect(presenter.current?.title == "認識に失敗しました")
    #expect(presenter.current?.message == "音声認識が設定されていません")
    #expect(microphone.requestCount == 0)
    #expect(!recorder.isRecording)
    #expect(inserter.recordCount == 0)

    // 失敗の表示時間が過ぎたら待機へ戻る
    clock.advance(by: HUDConfiguration.defaultErrorDisplayDuration)
    hudScheduler.fire()
    #expect(session.phase == .idle)
    #expect(!presenter.isVisible)
  }

  @Test("4章: 音声認識が失敗したら録音を止め、認識の失敗を表示する")
  func recognitionFailure() async {
    let recorder = StubAudioRecorder()
    let session = coordinator(
      recorder: recorder, recognizer: StubSpeechRecognizer(steps: [.fail(.engineFailed)]))

    session.toggle()
    #expect(await eventually { session.phase == .error(.recognition) })
    #expect(await eventually { !recorder.isRecording })
    #expect(insertedTexts.isEmpty)
    #expect(presenter.current?.title == "認識に失敗しました")
    #expect(presenter.current?.message == nil)
  }

  @Test("7章: 失敗の表示中にキャンセルしても、一時音声の差し込み口には終わりを1回だけ伝える")
  func retentionEndsOnceOnCancelDuringError() async throws {
    let recorder = StubAudioRecorder()
    let session = coordinator(
      recorder: recorder, recognizer: StubSpeechRecognizer(steps: [.fail(.engineFailed)]))

    session.toggle()
    #expect(await eventually { session.phase == .error(.recognition) })
    #expect(session.canCancel)
    session.cancel()

    #expect(session.phase == .idle)
    let id = try #require(
      retention.events.first.flatMap { event -> SessionID? in
        if case .begin(let id) = event { return id }
        return nil
      })
    #expect(retention.lifecycle == [.begin(id), .end(id, completed: false)])
  }

  @Test("7章: STT 未設定で録音しなかったセッションは、一時音声の差し込み口に伝えない")
  func retentionUntouchedWithoutRecording() {
    let session = coordinator(recognizer: nil)

    session.toggle()
    session.cancel()

    #expect(session.phase == .idle)
    #expect(retention.events.isEmpty)
  }

  @Test("REC-04, PERM-02: マイクの使用が拒否されていたら、録音の失敗と理由を表示する")
  func microphoneDenied() async {
    let recorder = StubAudioRecorder(microphone: StubMicrophoneAccess(authorization: .denied))
    let session = coordinator(recorder: recorder)

    session.toggle()
    #expect(await eventually { session.phase == .error(.recording) })
    #expect(presenter.current?.message == "マイクの使用が許可されていません")
    #expect(insertedTexts.isEmpty)
  }

  // MARK: キャンセルと遅延イベント

  @Test("REC-01: 録音中のキャンセルで録音を止めて待機へ戻り、そのセッションの遅れた認識結果を捨てる")
  func cancelWhileRecordingIgnoresLateEvents() async throws {
    let recorder = StubAudioRecorder()
    let recognizer = ScriptedSpeechRecognizer()
    let session = coordinator(recorder: recorder, recognizer: recognizer)

    session.toggle()
    #expect(await eventually { recognizer.runCount == 1 })
    #expect(session.canCancel)
    session.cancel()

    #expect(session.phase == .idle)
    #expect(!presenter.isVisible)
    #expect(await eventually { !recorder.isRecording })
    recognizer.send(.completed("古い結果"), to: 0)

    // 次のセッションは古いセッションの結果に影響されない
    session.toggle()
    #expect(await eventually { recognizer.runCount == 2 })
    #expect(recognizer.session(of: 0) != recognizer.session(of: 1))
    session.toggle()
    recognizer.send(.completed("新しい結果"), to: 1)
    #expect(await eventually { session.phase == .idle && !insertedTexts.isEmpty })
    #expect(insertedTexts == ["新しい結果"])
    let first = try #require(recognizer.session(of: 0))
    #expect(retention.events.contains(.end(first, completed: false)))
  }

  @Test("REC-01: 認識中のキャンセルで待機へ戻り、後から届いた完了を挿入しない")
  func cancelWhileRecognizing() async {
    let recorder = StubAudioRecorder()
    let recognizer = ScriptedSpeechRecognizer()
    let session = coordinator(recorder: recorder, recognizer: recognizer)

    session.toggle()
    #expect(await eventually { recognizer.runCount == 1 && recorder.isRecording })
    session.toggle()
    #expect(session.phase == .recognizing)
    session.cancel()
    recognizer.send(.completed("捨てる"), to: 0)

    #expect(session.phase == .idle)
    // 認識のストリームを手放し（Worker の認識も止まる）、結果が届いても挿入しない
    #expect(await eventually { recognizer.isTerminated(0) && !recorder.isRecording })
    await Task.yield()
    #expect(insertedTexts.isEmpty)
  }

  @Test("4章: 別のセッション・順序の古い認識イベントは捨て、今のセッションの完了だけを使う")
  func ignoresMismatchedRecognitionEvents() async throws {
    let recorder = StubAudioRecorder()
    let recognizer = ScriptedSpeechRecognizer()
    let session = coordinator(recorder: recorder, recognizer: recognizer)

    session.toggle()
    #expect(await eventually { recognizer.runCount == 1 && recorder.isRecording })
    session.toggle()
    let current = try #require(recognizer.session(of: 0))

    recognizer.sendRaw(
      RecognitionEvent(sessionID: SessionID(), sequence: 0, kind: .completed("別のセッション")), to: 0)
    recognizer.sendRaw(
      RecognitionEvent(sessionID: current, sequence: 5, kind: .partial("途中")), to: 0)
    recognizer.sendRaw(
      RecognitionEvent(sessionID: current, sequence: 3, kind: .completed("順序が古い")), to: 0)
    recognizer.sendRaw(
      RecognitionEvent(sessionID: current, sequence: 6, kind: .completed("今の結果")), to: 0)

    #expect(await eventually { session.phase == .idle })
    #expect(insertedTexts == ["今の結果"])
  }

  @Test("REC-01: 挿入が始まったらキャンセルを受け付けない")
  func cancelIgnoredWhileInserting() async {
    inserter.holdsInsertion = true
    let recorder = StubAudioRecorder()
    let session = coordinator(recorder: recorder)

    session.toggle()
    #expect(await eventually { recorder.isRecording })
    session.toggle()
    #expect(await eventually { inserter.isHoldingInsertion })
    #expect(session.phase == .inserting)
    #expect(!session.canCancel)
    session.cancel()
    #expect(session.phase == .inserting)

    inserter.resumeInsertion()
    #expect(await eventually { session.phase == .idle })
    #expect(insertedTexts == ["こんにちは"])
  }

  @Test("REC-04: マイクの使用許可を待つ間に停止したら、録音を始めずに待機へ戻る")
  func stopWhileAskingPermission() async {
    let microphone = GatedMicrophoneAccess()
    let recorder = StubAudioRecorder(microphone: microphone)
    let session = coordinator(recorder: recorder)

    session.toggle()
    #expect(await eventually { microphone.isAsking })
    session.toggle()
    #expect(session.phase == .recognizing)
    microphone.answer(true)

    #expect(await eventually { session.phase == .idle })
    #expect(!recorder.isRecording)
    #expect(insertedTexts.isEmpty)
  }

  // MARK: 連打

  @Test("REC-04, REC-06: 連打しても録音は1つで、処理中の開始操作は無視する")
  func rapidPresses() async {
    let recorder = StubAudioRecorder()
    let recognizer = ScriptedSpeechRecognizer()
    let session = coordinator(recorder: recorder, recognizer: recognizer)

    session.perform(.startRecording)
    session.perform(.startRecording)
    #expect(await eventually { recorder.isRecording })
    session.perform(.stopRecording)
    session.toggle()
    session.perform(.startRecording)
    #expect(session.phase == .recognizing)

    recognizer.send(.completed("一回だけ"), to: 0)
    #expect(await eventually { session.phase == .idle })
    #expect(recognizer.runCount == 1)
    #expect(insertedTexts == ["一回だけ"])
  }

  // MARK: 上限と割り込み

  @Test("REC-05: 最大録音時間に達したら録音を止めて処理を続け、完了後も通知を残す")
  func stopsAtMaxDuration() async throws {
    let configuration = try SessionConfiguration(maxRecordingDuration: .seconds(10))
    let recorder = StubAudioRecorder()
    let session = coordinator(recorder: recorder, configuration: configuration)

    session.toggle()
    #expect(deadlineScheduler.deadline == clock.now.advanced(by: .seconds(10)))
    #expect(await eventually { recorder.isRecording })

    // 期限より早く発火したら予約し直す
    clock.advance(by: .seconds(5))
    deadlineScheduler.fire()
    #expect(session.phase == .recording)
    #expect(deadlineScheduler.deadline != nil)

    clock.advance(by: .seconds(5))
    deadlineScheduler.fire()
    #expect(session.activeSession?.stopReason == .maxDurationReached)
    #expect(presenter.current?.message == "最大録音時間に達したため、録音を停止しました")
    #expect(await eventually { session.phase == .idle })

    #expect(insertedTexts == ["こんにちは"])
    #expect(presenter.current?.title == "最大録音時間に達したため、録音を停止しました")
    #expect(!recorder.isRecording)
  }

  @Test("REC-05: 設定で変えた最大録音時間は次のセッションから使い、録音中のセッションは変えない")
  func maxDurationChangeAppliesToNextSession() async throws {
    let recorder = StubAudioRecorder()
    let recognizer = ScriptedSpeechRecognizer()
    let session = coordinator(recorder: recorder, recognizer: recognizer)

    let firstStart = clock.now
    session.toggle()
    #expect(await eventually { recognizer.runCount == 1 && recorder.isRecording })
    session.useSettings(
      SessionSettings(configuration: try SessionConfiguration(maxRecordingDuration: .seconds(10))))

    // 録音中のセッションは元の最大録音時間（既定の5分）のまま。新しい最大録音時間を過ぎても止めない
    clock.advance(by: .seconds(11))
    deadlineScheduler.fire()
    #expect(session.phase == .recording)
    #expect(deadlineScheduler.deadline == firstStart.advanced(by: .seconds(300)))

    session.cancel()
    #expect(await eventually { !recorder.isRecording })

    // 次のセッションから新しい最大録音時間を使う
    let secondStart = clock.now
    session.toggle()
    #expect(deadlineScheduler.deadline == secondStart.advanced(by: .seconds(10)))
    #expect(await eventually { recognizer.runCount == 2 && recorder.isRecording })
    clock.advance(by: .seconds(10))
    deadlineScheduler.fire()
    #expect(session.activeSession?.stopReason == .maxDurationReached)
    session.cancel()
  }

  @Test("REC-05: 音声バッファの上限に達したら録音を止め、音声を捨てずに処理する")
  func stopsAtBufferLimit() async throws {
    // バッファは最大録音時間 + 1秒（2秒分）
    let configuration = try SessionConfiguration(maxRecordingDuration: .seconds(1))
    let recorder = StubAudioRecorder()
    let recognizer = ScriptedSpeechRecognizer()
    let session = coordinator(
      recorder: recorder, recognizer: recognizer, configuration: configuration)

    session.toggle()
    #expect(await eventually { recorder.isRecording })
    recorder.feed([Float](repeating: 0.1, count: 16_000 * 3))

    #expect(await eventually { session.phase == .recognizing })
    #expect(session.activeSession?.stopReason == .bufferLimitReached)
    #expect(presenter.current?.message == "録音できる音声の上限に達したため、録音を停止しました")
    recognizer.send(.completed("上限まで"), to: 0)
    #expect(await eventually { session.phase == .idle })
    #expect(insertedTexts == ["上限まで"])
    #expect(await eventually { retention.appendedSampleCount == 16_000 * 2 })
  }

  @Test("REC-05: 最大録音時間の端数も音声バッファの上限に含める（端数を切り捨てて早く止めない）")
  func bufferIncludesFractionalDuration() async throws {
    // バッファは 1.5 + 1 = 2.5 秒分。2.2 秒分（100ms のチャンク 22 個）を入れても上限に達しない
    let configuration = try SessionConfiguration(maxRecordingDuration: .milliseconds(1_500))
    let recorder = StubAudioRecorder()
    let session = coordinator(recorder: recorder, configuration: configuration)

    session.toggle()
    #expect(await eventually { recorder.isRecording })
    recorder.feed([Float](repeating: 0.1, count: 35_200))
    #expect(await eventually { retention.appendedSampleCount == 35_200 })
    #expect(session.phase == .recording)
    #expect(recorder.isRecording)
    session.cancel()
  }

  @Test("REC-04: 入力機器が使えなくなったら録音を止め、それまでの音声を処理して通知する")
  func interruptionStopsAndProcesses() async {
    let recorder = StubAudioRecorder()
    let recognizer = ScriptedSpeechRecognizer()
    let session = coordinator(recorder: recorder, recognizer: recognizer)

    session.toggle()
    #expect(await eventually { recorder.isRecording })
    recorder.feed([Float](repeating: 0.1, count: 3_200))
    recorder.interrupt(.audioRouteChanged(.inputDeviceLost))

    #expect(await eventually { session.phase == .recognizing })
    #expect(session.activeSession?.stopReason == .interrupted(.inputDeviceLost))
    #expect(presenter.current?.message == "マイクが使えなくなったため、録音を停止しました")
    recognizer.send(.completed("途中まで"), to: 0)
    #expect(await eventually { session.phase == .idle })
    #expect(insertedTexts == ["途中まで"])
  }

  @Test(
    "REC-04: macOS の割り込み（構成変更・スリープ）で録音を止めたら、それまでの音声を処理して macOS の理由を通知する",
    arguments: [
      (MacRecordingInterruptions.configurationChange, "入力機器が切り替わったため、録音を停止しました"),
      (MacRecordingInterruptions.willSleep, "Mac がスリープしたため、録音を停止しました"),
    ])
  func macOSInterruptionStopsAndProcesses(interruption: RecordingInterruption, message: String)
    async
  {
    let recorder = StubAudioRecorder()
    let recognizer = ScriptedSpeechRecognizer()
    let session = coordinator(recorder: recorder, recognizer: recognizer)

    session.toggle()
    #expect(await eventually { recorder.isRecording })
    recorder.feed([Float](repeating: 0.1, count: 3_200))
    recorder.interrupt(interruption)

    #expect(await eventually { session.phase == .recognizing })
    #expect(presenter.current?.messages == [message])
    recognizer.send(.completed("途中まで"), to: 0)
    #expect(await eventually { session.phase == .idle })
    #expect(insertedTexts == ["途中まで"])
  }

  @Test("iOS-PERF-03: 処理できる音声がないまま割り込まれたら、録音の失敗を表示して認識を止める")
  func interruptionWithoutAudioAborts() async {
    let recorder = StubAudioRecorder()
    let recognizer = ScriptedSpeechRecognizer()
    let session = coordinator(recorder: recorder, recognizer: recognizer)

    session.toggle()
    #expect(await eventually { recorder.isRecording && recognizer.runCount == 1 })
    recorder.interrupt(.audioInterruptionBegan)

    #expect(await eventually { session.phase == .error(.recording) })
    #expect(presenter.current?.message == "ほかの音声に割り込まれたため、録音を停止しました")
    // 認識のストリームを手放し、結果が届いても挿入しない
    #expect(await eventually { recognizer.isTerminated(0) })
    recognizer.send(.completed("届いても使わない"), to: 0)
    await Task.yield()
    #expect(insertedTexts.isEmpty)
    #expect(session.phase == .error(.recording))
  }

  // MARK: STT Worker の異常終了からの再処理（7章, AC-10）

  @Test("AC-10: 認識中に Worker が異常終了したら、録音全体で同じセッションID のまま認識し直して挿入する")
  func recognizesAgainAfterTerminationWhileRecognizing() async throws {
    let recorder = StubAudioRecorder()
    let recognizer = ScriptedSpeechRecognizer()
    let recovery = StubRecognitionRecovery(answer: true)
    let session = coordinator(recorder: recorder, recognizer: recognizer, recovery: recovery)

    session.toggle()
    #expect(await eventually { recognizer.runCount == 1 && recorder.isRecording })
    recorder.feed([Float](repeating: 0.1, count: 1_600))
    session.toggle()
    #expect(await eventually { recognizer.isAudioFinished(0) })
    recognizer.send(.failed(.engineFailed), to: 0)

    #expect(await eventually { recognizer.runCount == 2 })
    #expect(session.phase == .recognizing)
    #expect(recovery.questions == [.engineFailed])
    let id = try #require(recognizer.session(of: 0))
    #expect(recognizer.session(of: 1) == id)
    #expect(await eventually { recognizer.isAudioFinished(1) })
    #expect(recognizer.sampleCount(of: 1) == 1_600)
    recognizer.send(.completed("やり直した結果"), to: 1)

    #expect(await eventually { session.phase == .idle })
    #expect(insertedTexts == ["やり直した結果"])
    #expect(retention.events == [.begin(id), .finishRecording(id), .end(id, completed: true)])
  }

  @Test("AC-10: 録音中に Worker が異常終了しても録音を続け、停止後に録音全体で認識し直す")
  func keepsRecordingAfterTerminationWhileRecording() async {
    let recorder = StubAudioRecorder()
    let recognizer = ScriptedSpeechRecognizer()
    let recovery = StubRecognitionRecovery(answer: true)
    let session = coordinator(recorder: recorder, recognizer: recognizer, recovery: recovery)

    session.toggle()
    #expect(await eventually { recognizer.runCount == 1 && recorder.isRecording })
    recorder.feed([Float](repeating: 0.1, count: 1_600))
    #expect(await eventually { recognizer.sampleCount(of: 0) == 1_600 })
    recognizer.send(.failed(.engineFailed), to: 0)
    #expect(
      await eventually { recognizer.isTerminated(0) && recovery.questions == [.engineFailed] })

    // 録音は止まらず、利用者の停止を待つ
    for _ in 0..<100 { await Task.yield() }
    #expect(session.phase == .recording)
    #expect(recorder.isRecording)
    recorder.feed([Float](repeating: 0.2, count: 800))
    session.toggle()

    #expect(await eventually { recognizer.runCount == 2 })
    #expect(await eventually { recognizer.isAudioFinished(1) })
    #expect(recognizer.sampleCount(of: 1) == 2_400)
    recognizer.send(.completed("全体"), to: 1)
    #expect(await eventually { session.phase == .idle })
    #expect(insertedTexts == ["全体"])
  }

  @Test("AC-10: 異常終了でない失敗（やり直さない判断）では、認識し直さずに失敗を表示し、一時音声を手放す")
  func failsWithoutRecognizingAgain() async throws {
    let recorder = StubAudioRecorder()
    let recognizer = ScriptedSpeechRecognizer()
    let recovery = StubRecognitionRecovery(answer: false)
    let session = coordinator(recorder: recorder, recognizer: recognizer, recovery: recovery)

    session.toggle()
    #expect(await eventually { recognizer.runCount == 1 && recorder.isRecording })
    recognizer.send(.failed(.resourceLimited), to: 0)

    #expect(await eventually { session.phase == .error(.recognition) })
    #expect(await eventually { !recorder.isRecording })
    #expect(recovery.questions == [.resourceLimited])
    #expect(recognizer.runCount == 1)
    let id = try #require(recognizer.session(of: 0))
    #expect(retention.lifecycle == [.begin(id), .end(id, completed: false)])
  }

  @Test("AC-10: 認識し直しても失敗したら、もう一度はやり直さずに失敗を表示する")
  func failsWhenRecognitionAgainFails() async throws {
    let recorder = StubAudioRecorder()
    let recognizer = ScriptedSpeechRecognizer()
    let recovery = StubRecognitionRecovery(answer: true)
    let session = coordinator(recorder: recorder, recognizer: recognizer, recovery: recovery)

    session.toggle()
    #expect(await eventually { recognizer.runCount == 1 && recorder.isRecording })
    recorder.feed([Float](repeating: 0.1, count: 1_600))
    session.toggle()
    recognizer.send(.failed(.engineFailed), to: 0)
    #expect(await eventually { recognizer.runCount == 2 })
    recognizer.send(.failed(.engineFailed), to: 1)

    #expect(await eventually { session.phase == .error(.recognition) })
    #expect(recognizer.runCount == 2)
    #expect(recovery.questions == [.engineFailed])
    #expect(insertedTexts.isEmpty)
    let id = try #require(recognizer.session(of: 0))
    #expect(retention.lifecycle == [.begin(id), .end(id, completed: false)])
  }

  @Test("AC-10, REC-01: 認識し直している間にキャンセルしたら、結果が届いても挿入しない")
  func cancelWhileRecognizingAgain() async {
    let recorder = StubAudioRecorder()
    let recognizer = ScriptedSpeechRecognizer()
    let session = coordinator(
      recorder: recorder, recognizer: recognizer,
      recovery: StubRecognitionRecovery(answer: true))

    session.toggle()
    #expect(await eventually { recognizer.runCount == 1 && recorder.isRecording })
    recorder.feed([Float](repeating: 0.1, count: 1_600))
    session.toggle()
    recognizer.send(.failed(.engineFailed), to: 0)
    #expect(await eventually { recognizer.runCount == 2 })
    session.cancel()

    #expect(session.phase == .idle)
    #expect(await eventually { recognizer.isTerminated(1) })
    recognizer.send(.completed("捨てる"), to: 1)
    for _ in 0..<100 { await Task.yield() }
    #expect(insertedTexts.isEmpty)
    #expect(session.phase == .idle)
  }

  @Test("AC-10, REC-06: 起動時の復旧で止めている間は開始操作を無視し、解いたら受け付ける")
  func ignoresStartWhileSuspended() async {
    let recorder = StubAudioRecorder()
    let session = coordinator(recorder: recorder)

    #expect(session.suspendIfIdle())
    #expect(!session.suspendIfIdle())
    session.toggle()
    #expect(session.phase == .idle)
    #expect(inserter.recordCount == 0)

    session.resume()
    session.toggle()
    #expect(session.phase == .recording)
    // 録音中は止められない
    #expect(!session.suspendIfIdle())
    session.cancel()
  }
}

/// `onPhaseChange` で受け取った状態の記録
@MainActor
private final class PhaseLog {
  var phases: [SessionPhase] = []
}
