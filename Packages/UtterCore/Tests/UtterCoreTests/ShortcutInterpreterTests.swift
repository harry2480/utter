import Testing

@testable import UtterCore

/// 開始操作を無視する処理中の状態
private let processingPhases: [SessionPhase] = [
  .recognizing, .refining, .inserting, .error(.recognition),
]

struct ShortcutInterpreterTests {
  let t0 = ContinuousClock.now

  // MARK: - Toggle

  @Test("REC-01: Toggle は1回目の押下で開始、2回目の押下で停止する")
  func toggleStartsAndStops() {
    var interpreter = ShortcutInterpreter(mode: .toggle)
    var machine = SessionStateMachine()

    let first = interpreter.handle(.shortcutPressed(isRepeat: false), phase: machine.phase)
    #expect(first == .consumed(.startRecording))
    machine.start(at: t0)

    let release = interpreter.handle(.shortcutReleased, phase: machine.phase)
    #expect(release == .consumed(nil))
    #expect(machine.phase == .recording)

    let second = interpreter.handle(.shortcutPressed(isRepeat: false), phase: machine.phase)
    #expect(second == .consumed(.stopRecording))
    machine.stopRecording(at: t0 + .seconds(3))
    #expect(machine.phase == .recognizing)
    #expect(machine.activeSession?.stopReason == .manual)
  }

  @Test("REC-04: キーリピートの押下は操作にしない", arguments: [ShortcutTriggerMode.toggle, .pushToTalk])
  func ignoresKeyRepeat(_ mode: ShortcutTriggerMode) {
    var interpreter = ShortcutInterpreter(mode: mode)

    let decision1 = interpreter.handle(.shortcutPressed(isRepeat: true), phase: .idle)
    #expect(decision1 == .consumed(nil))
    let decision2 = interpreter.handle(.shortcutPressed(isRepeat: true), phase: .recording)
    #expect(decision2 == .consumed(nil))
  }

  @Test(
    "REC-06: 処理中の開始操作は無視する",
    arguments: [ShortcutTriggerMode.toggle, .pushToTalk], processingPhases)
  func ignoresPressWhileProcessing(_ mode: ShortcutTriggerMode, _ phase: SessionPhase) {
    var interpreter = ShortcutInterpreter(mode: mode)

    let decision1 = interpreter.handle(.shortcutPressed(isRepeat: false), phase: phase)
    #expect(decision1 == .consumed(nil))
    let decision2 = interpreter.handle(.shortcutReleased, phase: phase)
    #expect(decision2 == .consumed(nil))
  }

  // MARK: - Push-to-talk

  @Test("REC-02: Push-to-talk は押下で開始、解放で停止する")
  func pushToTalkStartsAndStops() {
    var interpreter = ShortcutInterpreter(mode: .pushToTalk)
    var machine = SessionStateMachine()

    let press = interpreter.handle(.shortcutPressed(isRepeat: false), phase: machine.phase)
    #expect(press == .consumed(.startRecording))
    machine.start(at: t0)

    let repeated = interpreter.handle(.shortcutPressed(isRepeat: true), phase: machine.phase)
    #expect(repeated == .consumed(nil))

    let release = interpreter.handle(.shortcutReleased, phase: machine.phase)
    #expect(release == .consumed(.stopRecording))
    machine.stopRecording(at: t0 + .seconds(2))
    #expect(machine.phase == .recognizing)
  }

  @Test("REC-05: Push-to-talk の押下中に自動停止したら、解放では何もしない")
  func pushToTalkReleaseAfterAutoStop() {
    var interpreter = ShortcutInterpreter(mode: .pushToTalk)
    var machine = SessionStateMachine()
    _ = interpreter.handle(.shortcutPressed(isRepeat: false), phase: machine.phase)
    machine.start(at: t0)
    machine.stopRecordingIfLimitReached(at: t0 + SessionConfiguration.defaultMaxRecordingDuration)
    #expect(machine.phase == .recognizing)

    let decision1 = interpreter.handle(.shortcutReleased, phase: machine.phase)
    #expect(decision1 == .consumed(nil))
  }

  @Test("REC-02: Push-to-talk で開始していない録音は解放で停止しない")
  func pushToTalkReleaseWithoutOwnPress() {
    var interpreter = ShortcutInterpreter(mode: .pushToTalk)

    let decision1 = interpreter.handle(.shortcutReleased, phase: .recording)
    #expect(decision1 == .consumed(nil))
    let decision2 = interpreter.handle(.shortcutReleased, phase: .idle)
    #expect(decision2 == .consumed(nil))
  }

  @Test("REC-04: Push-to-talk で解放を取りこぼしても、次の押下で録音を停止できる")
  func pushToTalkRecoversFromMissedRelease() {
    var interpreter = ShortcutInterpreter(mode: .pushToTalk)
    _ = interpreter.handle(.shortcutPressed(isRepeat: false), phase: .idle)

    let press = interpreter.handle(.shortcutPressed(isRepeat: false), phase: .recording)
    #expect(press == .consumed(.stopRecording))
    let decision1 = interpreter.handle(.shortcutReleased, phase: .recognizing)
    #expect(decision1 == .consumed(nil))
  }

  @Test("REC-02: 操作方式を変えると Push-to-talk の押下状態を破棄する")
  func changingModeResetsPushToTalk() {
    var interpreter = ShortcutInterpreter(mode: .pushToTalk)
    _ = interpreter.handle(.shortcutPressed(isRepeat: false), phase: .idle)

    interpreter.mode = .toggle
    interpreter.mode = .pushToTalk

    let decision1 = interpreter.handle(.shortcutReleased, phase: .recording)
    #expect(decision1 == .consumed(nil))
  }

  @Test("REC-04: reset で Push-to-talk の押下状態を破棄する")
  func resetClearsPushToTalk() {
    var interpreter = ShortcutInterpreter(mode: .pushToTalk)
    _ = interpreter.handle(.shortcutPressed(isRepeat: false), phase: .idle)

    interpreter.reset()

    let decision1 = interpreter.handle(.shortcutReleased, phase: .recording)
    #expect(decision1 == .consumed(nil))
  }

  // MARK: - Esc

  @Test(
    "REC-01: 録音〜整形中は Esc を捕捉してキャンセルする",
    arguments: [SessionPhase.recording, .recognizing, .refining])
  func escapeCancelsDuringSession(_ phase: SessionPhase) {
    var interpreter = ShortcutInterpreter(mode: .toggle)

    #expect(ShortcutInterpreter.capturesEscape(in: phase))
    let decision1 = interpreter.handle(.escapePressed, phase: phase)
    #expect(decision1 == .consumed(.cancelSession))
  }

  @Test(
    "REC-01: 待機中・挿入中・失敗の表示中は Esc を捕捉しない",
    arguments: [SessionPhase.idle, .inserting, .error(.insertion)])
  func escapePassesThroughOutsideSession(_ phase: SessionPhase) {
    var interpreter = ShortcutInterpreter(mode: .toggle)

    #expect(!ShortcutInterpreter.capturesEscape(in: phase))
    let decision1 = interpreter.handle(.escapePressed, phase: phase)
    #expect(decision1 == .passThrough)
  }

  @Test("REC-01: Esc でキャンセルした後の Push-to-talk の解放は何もしない")
  func pushToTalkReleaseAfterEscape() {
    var interpreter = ShortcutInterpreter(mode: .pushToTalk)
    var machine = SessionStateMachine()
    _ = interpreter.handle(.shortcutPressed(isRepeat: false), phase: machine.phase)
    machine.start(at: t0)

    let decision1 = interpreter.handle(.escapePressed, phase: machine.phase)
    #expect(decision1 == .consumed(.cancelSession))
    machine.cancel()
    #expect(machine.phase == .idle)

    let decision2 = interpreter.handle(.shortcutReleased, phase: machine.phase)
    #expect(decision2 == .consumed(nil))
    let decision3 = interpreter.handle(.escapePressed, phase: machine.phase)
    #expect(decision3 == .passThrough)
  }
}
