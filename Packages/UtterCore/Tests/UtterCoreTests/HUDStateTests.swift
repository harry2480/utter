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

  @Test("AC-16: ローカル整形へ退避したら、整形中から挿入中まで退避の通知を表示する")
  func showsFallbackNoticeWhileProcessing() throws {
    var hud = HUDState()
    var machine = SessionStateMachine()
    machine.start(at: t0)
    machine.stopRecording(at: t0)
    _ = try machine.handle(event(machine, .recognitionCompleted))
    hud.update(from: machine, at: t0)
    let session = try #require(machine.activeSession)

    hud.recordRefinementFallback(.timeout, for: session.id)
    #expect(
      hud.content(at: t0) == HUDContent(status: .refining, notice: .refinementFellBack(.timeout)))

    _ = try machine.handle(event(machine, .refinementCompleted))
    hud.update(from: machine, at: t0)
    #expect(
      hud.content(at: t0) == HUDContent(status: .inserting, notice: .refinementFellBack(.timeout)))
  }

  @Test("AC-16: 退避したセッションが完了した後も、設定した時間だけ退避の通知を残す")
  func keepsFallbackNoticeAfterCompletion() throws {
    let configuration = try HUDConfiguration(
      errorDisplayDuration: .seconds(3), limitNoticeDisplayDuration: .seconds(4))
    var hud = HUDState(configuration: configuration)
    var machine = try machineRefining(after: .manual)
    hud.update(from: machine, at: t0)
    hud.recordRefinementFallback(.networkUnavailable, for: try #require(machine.activeSession).id)
    _ = try machine.handle(event(machine, .refinementCompleted))
    hud.update(from: machine, at: t0)

    _ = try machine.handle(event(machine, .insertionCompleted))
    hud.update(from: machine, at: t0 + .seconds(1))

    #expect(hud.noticeExpiry == t0 + .seconds(5))
    #expect(
      hud.content(at: t0 + .seconds(4))
        == HUDContent(status: nil, notice: .refinementFellBack(.networkUnavailable)))
    #expect(hud.content(at: t0 + .seconds(5)) == nil)
  }

  @Test("REC-05, AC-16: 上限到達と退避が重なったら、両方の通知を停止・退避の順に表示して残す")
  func showsLimitAndFallbackNoticesTogether() throws {
    var hud = HUDState()
    var machine = try machineRefining(after: .bufferLimit)
    hud.update(from: machine, at: t0)
    hud.recordRefinementFallback(.validationFailed, for: try #require(machine.activeSession).id)
    let both: [HUDNotice] = [.audioBufferLimitReached, .refinementFellBack(.validationFailed)]
    #expect(hud.content(at: t0) == HUDContent(status: .refining, notices: both))
    #expect(hud.content(at: t0)?.notice == .audioBufferLimitReached)

    _ = try machine.handle(event(machine, .refinementCompleted))
    hud.update(from: machine, at: t0)
    _ = try machine.handle(event(machine, .insertionCompleted))
    hud.update(from: machine, at: t0)

    #expect(hud.content(at: t0) == HUDContent(status: nil, notices: both))
    #expect(hud.noticeExpiry == t0 + HUDConfiguration.defaultLimitNoticeDisplayDuration)
  }

  @Test("AC-16: 挿入に失敗したら退避の通知を失敗と一緒に表示し、表示を終えたら残さない")
  func failureAfterFallbackShowsNotice() throws {
    var hud = HUDState()
    var machine = try machineRefining(after: .manual)
    hud.update(from: machine, at: t0)
    hud.recordRefinementFallback(.consentNotGranted, for: try #require(machine.activeSession).id)
    _ = try machine.handle(event(machine, .refinementCompleted))
    _ = try machine.handle(event(machine, .failed))
    hud.update(from: machine, at: t0)
    #expect(
      hud.content(at: t0)
        == HUDContent(status: .failed(.insertion), notice: .refinementFellBack(.consentNotGranted)))

    machine.dismissError()
    hud.update(from: machine, at: t0)
    #expect(hud.content(at: t0) == nil)
    #expect(hud.noticeExpiry == nil)
  }

  @Test("AC-16: キャンセル・完了済みのセッションや別のセッションの退避は反映しない")
  func ignoresFallbackForInactiveSession() throws {
    var hud = HUDState()
    var machine = try machineRefining(after: .manual)
    hud.update(from: machine, at: t0)
    let cancelled = try #require(machine.activeSession).id

    machine.cancel()
    hud.update(from: machine, at: t0)
    hud.recordRefinementFallback(.timeout, for: cancelled)
    #expect(hud.content(at: t0) == nil)

    machine.start(at: t0 + .seconds(1))
    hud.update(from: machine, at: t0 + .seconds(1))
    hud.recordRefinementFallback(.timeout, for: cancelled)
    #expect(hud.content(at: t0 + .seconds(1)) == HUDContent(status: .recording, notice: nil))
  }

  /// 挿入中のキャンセルは状態機械が受け付けないため（REC-01）、整形中のキャンセルだけを確かめる。
  @Test("AC-16: 退避を反映した後に整形中でキャンセルしたら、退避の通知を残さない")
  func cancelAfterFallbackClearsNotice() throws {
    var hud = HUDState()
    var machine = try machineRefining(after: .bufferLimit)
    hud.update(from: machine, at: t0)
    hud.recordRefinementFallback(.timeout, for: try #require(machine.activeSession).id)

    machine.cancel()
    hud.update(from: machine, at: t0)

    #expect(hud.content(at: t0) == nil)
    #expect(hud.noticeExpiry == nil)
  }

  @Test("AC-16: 同じセッションで複数回反映したら最後の理由を表示する")
  func latestFallbackWins() throws {
    var hud = HUDState()
    let machine = try machineRefining(after: .manual)
    hud.update(from: machine, at: t0)
    let session = try #require(machine.activeSession).id

    hud.recordRefinementFallback(.timeout, for: session)
    hud.recordRefinementFallback(.budgetExceeded, for: session)

    #expect(
      hud.content(at: t0)
        == HUDContent(status: .refining, notice: .refinementFellBack(.budgetExceeded)))
  }

  @Test("AC-16: 整形中を反映する前・整形中でないときの退避は反映しない")
  func ignoresFallbackOutsideRefining() throws {
    var hud = HUDState()
    var machine = SessionStateMachine()
    machine.start(at: t0)
    machine.stopRecording(at: t0)
    hud.update(from: machine, at: t0)
    let session = try #require(machine.activeSession).id

    // 認識中
    hud.recordRefinementFallback(.timeout, for: session)
    #expect(hud.content(at: t0) == HUDContent(status: .recognizing, notice: nil))

    // 整形中になったが、HUD へまだ反映していない
    _ = try machine.handle(event(machine, .recognitionCompleted))
    hud.recordRefinementFallback(.timeout, for: session)
    hud.update(from: machine, at: t0)
    #expect(hud.content(at: t0) == HUDContent(status: .refining, notice: nil))

    // 整形が失敗した後
    _ = try machine.handle(event(machine, .failed))
    hud.update(from: machine, at: t0)
    hud.recordRefinementFallback(.timeout, for: session)
    #expect(hud.content(at: t0) == HUDContent(status: .failed(.refinement), notice: nil))
  }

  @Test("AC-16: 新しいセッションを始めたら前のセッションの退避を引き継がない")
  func newSessionDoesNotInheritFallback() throws {
    var hud = HUDState()
    var machine = try machineRefining(after: .manual)
    hud.update(from: machine, at: t0)
    hud.recordRefinementFallback(.quotaExceeded, for: try #require(machine.activeSession).id)
    _ = try machine.handle(event(machine, .refinementCompleted))
    hud.update(from: machine, at: t0)
    _ = try machine.handle(event(machine, .insertionCompleted))
    hud.update(from: machine, at: t0)

    machine.start(at: t0 + .seconds(1))
    hud.update(from: machine, at: t0 + .seconds(1))
    machine.stopRecording(at: t0 + .seconds(2))
    _ = try machine.handle(event(machine, .recognitionCompleted))
    hud.update(from: machine, at: t0 + .seconds(2))

    #expect(hud.content(at: t0 + .seconds(2)) == HUDContent(status: .refining, notice: nil))
  }

  @Test("AC-16, AI-06: 退避の種類ごとに別の通知になる")
  func fallbackKindsAreDistinctNotices() {
    let notices = Set(RefinementFallbackNotice.allCases.map(HUDNotice.refinementFellBack))
    #expect(notices.count == RefinementFallbackNotice.allCases.count)
    #expect(
      notices.isDisjoint(with: [
        .maxRecordingDurationReached, .audioBufferLimitReached,
        .recordingInterrupted(.audioInterruption),
      ]))
  }

  @Test("REC-05: 通知が1件以下の表示内容は、通知の配列と同じ値になる")
  func singleNoticeInitializerMatchesArray() {
    #expect(
      HUDContent(status: .recording, notice: nil) == HUDContent(status: .recording, notices: []))
    #expect(
      HUDContent(status: nil, notice: .maxRecordingDurationReached)
        == HUDContent(status: nil, notices: [.maxRecordingDurationReached]))
    #expect(HUDContent(status: nil, notices: []).notice == nil)
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
    var machine = try machineRefining(after: stop)
    _ = try machine.handle(event(machine, .refinementCompleted))
    return machine
  }

  private func machineRefining(after stop: Stop) throws -> SessionStateMachine {
    var machine = SessionStateMachine()
    machine.start(at: t0)
    switch stop {
    case .manual: machine.stopRecording(at: t0)
    case .bufferLimit: machine.stopRecordingAtBufferLimit()
    }
    _ = try machine.handle(event(machine, .recognitionCompleted))
    return machine
  }

  private func event(_ machine: SessionStateMachine, _ kind: SessionEvent.Kind) throws
    -> SessionEvent
  {
    SessionEvent(token: try #require(machine.currentToken), kind: kind)
  }
}
