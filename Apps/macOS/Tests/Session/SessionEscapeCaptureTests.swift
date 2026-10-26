import Testing
import UtterCore
import UtterSpeech

/// ショートカットの Esc 捕捉（#51 の判定待ち。capability は既定で無効）を、セッションの調停のキャンセルにつなぐ（REC-01）。
/// 録音・認識・挿入・HUD・イベントタップは Stub に置き換える。
@MainActor
struct SessionEscapeCaptureTests {
  let clock = ManualClock()
  let presenter = StubHUDPresenter()
  let hudScheduler = StubScheduler()
  let deadlineScheduler = StubScheduler()
  let inserter = StubSessionInserter()
  let recorder = StubAudioRecorder()
  let recognizer = ScriptedSpeechRecognizer()
  let registrar = StubHotKeyRegistrar()
  let taps = StubKeyEventTapFactory()
  let permissions = StubEventTapPermissions()
  let hud: HUDController

  init() {
    let clock = clock
    hud = HUDController(presenter: presenter, scheduler: hudScheduler, now: { clock.now })
    permissions.granted = [.accessibility]
  }

  /// アプリの組み立て（`AppComposition`）と同じように、セッションとショートカットをつなぐ
  private func wire(_ capabilities: ShortcutCapabilities) throws -> (
    SessionCoordinator, GlobalShortcutController
  ) {
    let clock = clock
    let session = SessionCoordinator(
      recorder: recorder,
      recognizer: recognizer,
      refinementMode: .raw,
      inserter: inserter,
      hud: hud,
      deadlineScheduler: deadlineScheduler,
      now: { clock.now })
    let controller = GlobalShortcutController(
      registrar: registrar,
      tapFactory: taps,
      permissions: permissions,
      capabilities: capabilities,
      systemShortcuts: { [] },
      currentPhase: { [weak session] in session?.phase ?? .idle },
      perform: { [weak session] command in session?.perform(command) })
    session.onPhaseChange = { [weak controller] in controller?.sessionPhaseDidChange() }
    controller.apply(try setting("ctrl+option+k"))
    return (session, controller)
  }

  @Test("REC-01: Esc 捕捉が有効なら、録音中の Esc でセッションをキャンセルし、Esc を他アプリへ渡さない")
  func escapeCancelsRecording() async throws {
    let (session, controller) = try wire(
      .init(supportsModifierOnly: false, supportsEscapeCapture: true))
    #expect(controller.escapeStatus == .ready)
    let tap = try #require(taps.live(.filter))
    #expect(!tap.isEnabled)

    registrar.send(.pressed)
    registrar.send(.released)
    #expect(session.phase == .recording)
    #expect(tap.isEnabled)
    #expect(await eventually { recognizer.runCount == 1 && recorder.isRecording })

    #expect(!tap.send(escape()))
    #expect(session.phase == .idle)
    #expect(!presenter.isVisible)
    #expect(await eventually { recognizer.isTerminated(0) && !recorder.isRecording })
    // 止めた Esc の解放まで止め、その後は待機中としてタップを無効に戻す
    #expect(!tap.send(escape(.keyUp)))
    #expect(!tap.isEnabled)
    #expect(inserter.inserted.isEmpty)
    extendLifetime(controller)
  }

  @Test("REC-01: 認識中も Esc でキャンセルできる。後から届いた完了は挿入しない")
  func escapeCancelsRecognition() async throws {
    let (session, controller) = try wire(
      .init(supportsModifierOnly: false, supportsEscapeCapture: true))
    let tap = try #require(taps.live(.filter))
    session.toggle()
    #expect(await eventually { recognizer.runCount == 1 && recorder.isRecording })
    // メニューからの停止（ショートカット以外の操作）でも捕捉を続ける
    session.toggle()
    #expect(session.phase == .recognizing)
    #expect(tap.isEnabled)

    #expect(!tap.send(escape()))
    tap.send(escape(.keyUp))
    #expect(session.phase == .idle)
    // 認識のストリームを手放すため、後から完了を送っても届かない
    #expect(await eventually { recognizer.isTerminated(0) })
    recognizer.send(.completed("捨てる"), to: 0)
    #expect(inserter.inserted.isEmpty)
    // コントローラーを解放するとタップも外れるため、最後まで保つ
    extendLifetime(controller)
  }

  @Test("REC-01: ショートカット以外の要因で待機に戻ったら、Esc のタップを無効に戻す（sessionPhaseDidChange）")
  func tapFollowsPhaseChangesOutsideShortcut() async throws {
    let (session, controller) = try wire(
      .init(supportsModifierOnly: false, supportsEscapeCapture: true))
    let tap = try #require(taps.live(.filter))

    // メニューから開始しても捕捉する
    session.toggle()
    #expect(tap.isEnabled)
    #expect(await eventually { recognizer.runCount == 1 && recorder.isRecording })
    session.toggle()
    recognizer.send(.completed("こんにちは"), to: 0)

    // 認識の完了 → 整形 → 挿入 → 待機と進んだら、待機中は他アプリの Esc に干渉しない
    #expect(await eventually { session.phase == .idle })
    #expect(!tap.isEnabled)
    #expect(tap.send(escape()))
    #expect(inserter.inserted.map(\.text) == ["こんにちは"])
    extendLifetime(controller)
  }

  @Test("REC-01: 認識の失敗（ショートカット以外の要因）で失敗の表示に移ったら、Esc のタップを無効に戻す")
  func tapDisabledOnRecognitionFailure() async throws {
    let (session, controller) = try wire(
      .init(supportsModifierOnly: false, supportsEscapeCapture: true))
    let tap = try #require(taps.live(.filter))
    session.toggle()
    #expect(await eventually { recognizer.runCount == 1 && recorder.isRecording })
    recognizer.send(.failed(.engineFailed), to: 0)
    #expect(await eventually { session.phase == .error(.recognition) })
    // 失敗の表示中は Esc を捕捉しない（ShortcutInterpreter.capturesEscape）
    #expect(!tap.isEnabled)
    #expect(tap.send(escape()))

    clock.advance(by: HUDConfiguration.defaultErrorDisplayDuration)
    hudScheduler.fire()
    #expect(session.phase == .idle)
    #expect(!tap.isEnabled)
    extendLifetime(controller)
  }

  @Test("REC-01: 状態が変わったときだけ onPhaseChange を呼ぶ")
  func phaseChangeNotifiedOnlyOnChange() async {
    let session = SessionCoordinator(
      recorder: recorder, recognizer: recognizer, refinementMode: .raw, inserter: inserter,
      hud: hud, deadlineScheduler: deadlineScheduler, now: { [clock] in clock.now })
    var phases: [SessionPhase] = []
    session.onPhaseChange = { [weak session] in phases.append(session?.phase ?? .idle) }

    session.toggle()
    #expect(await eventually { recognizer.runCount == 1 && recorder.isRecording })
    // 状態の変わらない操作では呼ばない
    session.startRecording()
    deadlineScheduler.fire()
    #expect(phases == [.recording])

    session.cancel()
    session.cancel()
    #expect(phases == [.recording, .idle])
  }

  @Test("REC-01: Esc 捕捉が無効（既定）ならタップを作らず、録音中の Esc でも何もしない")
  func escapeCaptureDisabledByDefault() async throws {
    let (session, controller) = try wire(.keyCombinationsOnly)
    #expect(controller.escapeStatus == .off)
    #expect(taps.created.isEmpty)
    #expect(permissions.checked.isEmpty)

    registrar.send(.pressed)
    registrar.send(.released)
    #expect(session.phase == .recording)
    #expect(await eventually { recorder.isRecording })
    // 状態が変わっても Esc のタップは作らない
    #expect(taps.created.isEmpty)
    #expect(session.phase == .recording)
    session.cancel()
  }
}
