import Testing

@testable import UtterCore

struct HUDStateTests {
  let t0 = ContinuousClock.now

  @Test("REC-03: 待機中は何も表示しない")
  func idleShowsNothing() {
    var hud = HUDState()
    hud.update(from: SessionStateMachine(), at: t0)

    #expect(hud.content(at: t0) == nil)
    #expect(hud.errorDismissDeadline == nil)
    #expect(hud.noticeExpiry == nil)
  }

  @Test("REC-03: 録音・認識・整形・挿入の状態を表示する")
  func showsEachStage() throws {
    var hud = HUDState()
    var machine = SessionStateMachine()

    machine.start(at: t0)
    hud.update(from: machine, at: t0)
    #expect(hud.content(at: t0) == HUDContent(status: .recording, notice: nil))

    machine.stopRecording(at: t0 + .seconds(1))
    hud.update(from: machine, at: t0 + .seconds(1))
    #expect(hud.content(at: t0 + .seconds(1)) == HUDContent(status: .recognizing, notice: nil))

    _ = try machine.handle(event(machine, .recognitionCompleted))
    hud.update(from: machine, at: t0 + .seconds(2))
    #expect(hud.content(at: t0 + .seconds(2)) == HUDContent(status: .refining, notice: nil))

    _ = try machine.handle(event(machine, .refinementCompleted))
    hud.update(from: machine, at: t0 + .seconds(3))
    #expect(hud.content(at: t0 + .seconds(3)) == HUDContent(status: .inserting, notice: nil))

    _ = try machine.handle(event(machine, .insertionCompleted))
    hud.update(from: machine, at: t0 + .seconds(4))
    #expect(hud.content(at: t0 + .seconds(4)) == nil)
  }

  @Test("REC-03: 失敗した段階を表示し、表示を終える時刻を知らせる")
  func showsFailureWithDeadline() throws {
    let configuration = try HUDConfiguration(
      errorDisplayDuration: .seconds(5), limitNoticeDisplayDuration: .seconds(2))
    var hud = HUDState(configuration: configuration)
    var machine = SessionStateMachine()
    machine.start(at: t0)
    machine.stopRecording(at: t0)
    _ = try machine.handle(event(machine, .failed))

    hud.update(from: machine, at: t0 + .seconds(1))
    #expect(
      hud.content(at: t0 + .seconds(1)) == HUDContent(status: .failed(.recognition), notice: nil))
    #expect(hud.errorDismissDeadline == t0 + .seconds(6))

    // 同じ状態で再度反映しても期限は延びない
    hud.update(from: machine, at: t0 + .seconds(3))
    #expect(hud.errorDismissDeadline == t0 + .seconds(6))

    machine.dismissError()
    hud.update(from: machine, at: t0 + .seconds(6))
    #expect(hud.content(at: t0 + .seconds(6)) == nil)
    #expect(hud.errorDismissDeadline == nil)
  }

  @Test("REC-05: 最大録音時間で自動停止したら、処理中に通知を表示する")
  func showsLimitNoticeWhileProcessing() throws {
    var hud = HUDState()
    var machine = SessionStateMachine()
    machine.start(at: t0)
    let limit = t0 + SessionConfiguration.defaultMaxRecordingDuration
    machine.stopRecordingIfLimitReached(at: limit)
    hud.update(from: machine, at: limit)

    #expect(
      hud.content(at: limit)
        == HUDContent(status: .recognizing, notice: .maxRecordingDurationReached))

    _ = try machine.handle(event(machine, .recognitionCompleted))
    hud.update(from: machine, at: limit)
    #expect(
      hud.content(at: limit) == HUDContent(status: .refining, notice: .maxRecordingDurationReached))
  }

  @Test("REC-05: 上限到達のセッションが完了した後も、設定した時間だけ通知を残す")
  func keepsLimitNoticeAfterCompletion() throws {
    let configuration = try HUDConfiguration(
      errorDisplayDuration: .seconds(3), limitNoticeDisplayDuration: .seconds(4))
    var hud = HUDState(configuration: configuration)
    var machine = try machineInserting(after: .bufferLimit)
    hud.update(from: machine, at: t0)
    #expect(hud.content(at: t0) == HUDContent(status: .inserting, notice: .audioBufferLimitReached))

    _ = try machine.handle(event(machine, .insertionCompleted))
    hud.update(from: machine, at: t0 + .seconds(1))

    #expect(hud.noticeExpiry == t0 + .seconds(5))
    #expect(
      hud.content(at: t0 + .seconds(4)) == HUDContent(status: nil, notice: .audioBufferLimitReached)
    )
    #expect(hud.content(at: t0 + .seconds(5)) == nil)

    // 待機のまま再度反映しても通知は消えない
    hud.update(from: machine, at: t0 + .seconds(2))
    #expect(
      hud.content(at: t0 + .seconds(2)) == HUDContent(status: nil, notice: .audioBufferLimitReached)
    )
  }

  @Test("REC-05: 手動停止のセッションでは通知を出さない")
  func noNoticeForManualStop() throws {
    var hud = HUDState()
    var machine = try machineInserting(after: .manual)
    hud.update(from: machine, at: t0)
    #expect(hud.content(at: t0) == HUDContent(status: .inserting, notice: nil))

    _ = try machine.handle(event(machine, .insertionCompleted))
    hud.update(from: machine, at: t0)
    #expect(hud.content(at: t0) == nil)
    #expect(hud.noticeExpiry == nil)
  }

  @Test("REC-05: キャンセルで待機に戻ったときは通知を残さない")
  func noLingeringNoticeAfterCancel() {
    var hud = HUDState()
    var machine = SessionStateMachine()
    machine.start(at: t0)
    machine.stopRecordingAtBufferLimit()
    hud.update(from: machine, at: t0)

    machine.cancel()
    hud.update(from: machine, at: t0)

    #expect(hud.content(at: t0) == nil)
  }

  @Test("REC-05: 失敗の表示中も上限到達の通知を表示し、表示を終えたら残さない")
  func failureAfterLimitShowsNotice() throws {
    var hud = HUDState()
    var machine = SessionStateMachine()
    machine.start(at: t0)
    machine.stopRecordingAtBufferLimit()
    _ = try machine.handle(event(machine, .failed))
    hud.update(from: machine, at: t0)
    #expect(
      hud.content(at: t0)
        == HUDContent(status: .failed(.recognition), notice: .audioBufferLimitReached))

    machine.dismissError()
    hud.update(from: machine, at: t0)
    #expect(hud.content(at: t0) == nil)
  }

  @Test("REC-05: 新しいセッションを始めたら残していた通知を消す")
  func newSessionClearsLingeringNotice() throws {
    var hud = HUDState()
    var machine = try machineInserting(after: .bufferLimit)
    hud.update(from: machine, at: t0)
    _ = try machine.handle(event(machine, .insertionCompleted))
    hud.update(from: machine, at: t0)

    machine.start(at: t0 + .seconds(1))
    hud.update(from: machine, at: t0 + .seconds(1))

    #expect(hud.content(at: t0 + .seconds(1)) == HUDContent(status: .recording, notice: nil))
    #expect(hud.noticeExpiry == nil)
  }

  @Test("REC-03: 表示時間の設定は正の値だけを受け付ける")
  func rejectsNonPositiveDurations() {
    #expect(throws: HUDConfigurationError.nonPositiveErrorDisplayDuration) {
      try HUDConfiguration(errorDisplayDuration: .zero, limitNoticeDisplayDuration: .seconds(1))
    }
    #expect(throws: HUDConfigurationError.nonPositiveLimitNoticeDisplayDuration) {
      try HUDConfiguration(
        errorDisplayDuration: .seconds(1), limitNoticeDisplayDuration: .seconds(-1))
    }
    let defaults = HUDConfiguration()
    #expect(defaults.errorDisplayDuration == HUDConfiguration.defaultErrorDisplayDuration)
    #expect(
      defaults.limitNoticeDisplayDuration == HUDConfiguration.defaultLimitNoticeDisplayDuration)
  }

  @Test("REC-03: 状態と停止理由から表示の区分を導く")
  func mapsPhaseAndStopReason() {
    #expect(HUDStatus(phase: .idle) == nil)
    #expect(HUDStatus(phase: .error(.insertion)) == .failed(.insertion))
    #expect(HUDNotice(stopReason: .manual) == nil)
    #expect(HUDNotice(stopReason: .maxDurationReached) == .maxRecordingDurationReached)
    #expect(HUDNotice(stopReason: .bufferLimitReached) == .audioBufferLimitReached)
    #expect(
      HUDNotice(stopReason: .interrupted(.audioInterruption))
        == .recordingInterrupted(.audioInterruption))
  }

  @Test(
    "REC-04: macOS の割り込みで録音を止めたら、処理中に理由を通知する",
    arguments: [
      (RecordingInterruption.systemWillSleep, RecordingInterruptionCause.systemSleep),
      (.audioRouteChanged(.inputDeviceChanged), .inputDeviceChanged),
      (.microphoneAccessRevoked, .microphoneAccessRevoked),
    ]
  )
  func showsMacOSInterruptionNotice(
    _ interruption: RecordingInterruption, _ cause: RecordingInterruptionCause
  ) {
    var hud = HUDState()
    var machine = SessionStateMachine()
    machine.start(at: t0)
    machine.handleInterruption(
      interruption, capturedAudioDuration: .seconds(1), policy: RecordingInterruptionPolicy())
    hud.update(from: machine, at: t0)

    #expect(
      hud.content(at: t0) == HUDContent(status: .recognizing, notice: .recordingInterrupted(cause)))
  }

  @Test("REC-04: 音声がないまま割り込みで中止したら、失敗と理由を表示する")
  func showsAbortedInterruptionNotice() {
    var hud = HUDState()
    var machine = SessionStateMachine()
    machine.start(at: t0)
    machine.handleInterruption(
      .systemWillSleep, capturedAudioDuration: .zero, policy: RecordingInterruptionPolicy())
    hud.update(from: machine, at: t0)

    #expect(
      hud.content(at: t0)
        == HUDContent(status: .failed(.recording), notice: .recordingInterrupted(.systemSleep)))
    #expect(hud.errorDismissDeadline == t0.advanced(by: hud.configuration.errorDisplayDuration))
  }

  // MARK: - Helpers

  enum Stop {
    case manual
    case bufferLimit
  }

  private func machineInserting(after stop: Stop) throws -> SessionStateMachine {
    var machine = SessionStateMachine()
    machine.start(at: t0)
    switch stop {
    case .manual: machine.stopRecording(at: t0)
    case .bufferLimit: machine.stopRecordingAtBufferLimit()
    }
    _ = try machine.handle(event(machine, .recognitionCompleted))
    _ = try machine.handle(event(machine, .refinementCompleted))
    return machine
  }

  private func event(_ machine: SessionStateMachine, _ kind: SessionEvent.Kind) throws
    -> SessionEvent
  {
    SessionEvent(token: try #require(machine.currentToken), kind: kind)
  }
}
