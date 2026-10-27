import Testing
import UtterCore
import UtterSpeech

/// Realtime Preview（2.2節, AC-03）の認識テキストを、セッションの調停から HUD へ渡す。認識は Stub のイベントで進める。
@MainActor
struct SessionRealtimePreviewTests {
  let clock = ManualClock()
  let presenter = StubHUDPresenter()
  let hudScheduler = StubScheduler()
  let deadlineScheduler = StubScheduler()
  let inserter = StubSessionInserter()
  let recorder = StubAudioRecorder()
  let recognizer = ScriptedSpeechRecognizer()
  let hud: HUDController

  init() {
    let clock = clock
    hud = HUDController(presenter: presenter, scheduler: hudScheduler, now: { clock.now })
  }

  private func coordinator(realtimePreview: Bool) -> SessionCoordinator {
    let clock = clock
    return SessionCoordinator(
      recorder: recorder,
      recognizer: recognizer,
      refiner: StubSessionRefiner(),
      showsRealtimePreview: realtimePreview,
      inserter: inserter,
      hud: hud,
      deadlineScheduler: deadlineScheduler,
      now: { clock.now })
  }

  private func transcript(_ confirmed: String, _ provisional: String) -> HUDTranscript {
    HUDTranscript(confirmedText: confirmed, provisionalText: provisional)
  }

  @Test("AC-03: Realtime Preview では録音中・認識中の HUD に確定済みと暫定のテキストを区別して出す")
  func showsConfirmedAndProvisional() async {
    let session = coordinator(realtimePreview: true)
    session.toggle()
    #expect(await eventually { recognizer.runCount == 1 && recorder.isRecording })
    #expect(presenter.current?.transcript == nil)

    recognizer.send(.partial("きょうは"), to: 0)
    #expect(await eventually { presenter.current?.transcript == transcript("", "きょうは") })
    #expect(presenter.current?.title == "録音中")

    recognizer.send(.confirmed("今日は"), to: 0)
    recognizer.send(.partial("いい"), to: 0)
    #expect(await eventually { presenter.current?.transcript == transcript("今日は", "いい") })

    // 停止後の認識中も出し続ける
    session.toggle()
    #expect(session.phase == .recognizing)
    #expect(presenter.current?.title == "認識中")
    #expect(presenter.current?.transcript == transcript("今日は", "いい"))
    recognizer.send(.confirmed("いい天気"), to: 0)
    #expect(await eventually { presenter.current?.transcript == transcript("今日はいい天気", "") })

    // 入力欄へは停止後に一括で挿入し、整形以降の段階には認識テキストを出さない
    recognizer.send(.completed("今日はいい天気"), to: 0)
    #expect(await eventually { session.phase == .idle })
    #expect(inserter.inserted.map(\.text) == ["今日はいい天気"])
    let afterRecognition = presenter.shown.drop { $0.title != "整形中" }
    #expect(afterRecognition.map(\.title) == ["整形中", "挿入中"])
    #expect(afterRecognition.allSatisfy { $0.transcript == nil })
  }

  @Test("2.2節: Instant（既定）では認識テキストを HUD に出さない")
  func instantShowsNoTranscript() async {
    let session = coordinator(realtimePreview: false)
    session.toggle()
    #expect(await eventually { recognizer.runCount == 1 && recorder.isRecording })
    recognizer.send(.partial("きょうは"), to: 0)
    recognizer.send(.confirmed("今日は"), to: 0)
    session.toggle()
    recognizer.send(.completed("今日は"), to: 0)
    #expect(await eventually { session.phase == .idle })

    #expect(inserter.inserted.map(\.text) == ["今日は"])
    #expect(presenter.shown.map(\.title) == ["録音中", "認識中", "整形中", "挿入中"])
    #expect(presenter.shown.allSatisfy { $0.transcript == nil })
  }

  @Test("2.2節: 設定で変えた入力モードは次のセッションから使い、録音中のセッションは変えない")
  func inputModeChangeAppliesToNextSession() async {
    let session = coordinator(realtimePreview: false)
    session.toggle()
    #expect(await eventually { recognizer.runCount == 1 && recorder.isRecording })
    session.useSettings(SessionSettings(showsRealtimePreview: true))

    // 録音中のセッションは Instant のまま、認識テキストを HUD に出さない
    recognizer.send(.partial("きょうは"), to: 0)
    session.toggle()
    recognizer.send(.completed("今日は"), to: 0)
    #expect(await eventually { session.phase == .idle })
    #expect(presenter.shown.allSatisfy { $0.transcript == nil })

    // 次のセッションから Realtime Preview で出す
    session.toggle()
    #expect(await eventually { recognizer.runCount == 2 && recorder.isRecording })
    recognizer.send(.partial("次の発話"), to: 1)
    #expect(await eventually { presenter.current?.transcript == transcript("", "次の発話") })
    session.cancel()
  }

  @Test("AC-03, REC-01: キャンセルしたら認識テキストを消し、次のセッションに前の発話を残さない")
  func cancelClearsTranscript() async {
    let session = coordinator(realtimePreview: true)
    session.toggle()
    #expect(await eventually { recognizer.runCount == 1 && recorder.isRecording })
    recognizer.send(.partial("前の発話"), to: 0)
    #expect(await eventually { presenter.current?.transcript != nil })

    session.cancel()
    #expect(!presenter.isVisible)
    // キャンセルしたセッションの認識のストリームは手放す（遅れたイベントは HUD に届かない）
    #expect(await eventually { recognizer.isTerminated(0) && !recorder.isRecording })
    session.toggle()
    #expect(await eventually { recognizer.runCount == 2 && recorder.isRecording })
    await Task.yield()
    #expect(presenter.current?.title == "録音中")
    #expect(presenter.current?.transcript == nil)

    recognizer.send(.partial("次の発話"), to: 1)
    #expect(await eventually { presenter.current?.transcript == transcript("", "次の発話") })
    session.cancel()
  }
}
