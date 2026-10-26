import Testing

@testable import UtterCore

@MainActor
struct HUDControllerTests {
  let clock = ManualClock()
  let presenter = RecordingPresenter()
  let scheduler = ManualScheduler()

  @Test("REC-03: 状態が変わったときだけ表示を更新し、待機に戻ったら隠す")
  func showsAndHidesWithSession() throws {
    let controller = makeController()
    var machine = SessionStateMachine()

    controller.update(from: machine)
    #expect(presenter.calls.isEmpty)

    machine.start(at: clock.now)
    controller.update(from: machine)
    controller.update(from: machine)
    #expect(presenter.calls == [.show(try presentation(.recording))])

    machine.stopRecording(at: clock.now)
    controller.update(from: machine)
    #expect(controller.presentation == (try presentation(.recognizing)))

    _ = try machine.handle(event(machine, .recognitionCompleted))
    controller.update(from: machine)
    _ = try machine.handle(event(machine, .refinementCompleted))
    controller.update(from: machine)
    _ = try machine.handle(event(machine, .insertionCompleted))
    controller.update(from: machine)

    #expect(
      presenter.calls == [
        .show(try presentation(.recording)),
        .show(try presentation(.recognizing)),
        .show(try presentation(.refining)),
        .show(try presentation(.inserting)),
        .hide,
      ])
    #expect(controller.presentation == nil)
    #expect(scheduler.deadline == nil)
  }

  @Test("REC-05: 上限到達の通知は挿入完了後も残し、表示時間が過ぎたら消す")
  func lingeringNoticeExpires() throws {
    let configuration = try HUDConfiguration(
      errorDisplayDuration: .seconds(5), limitNoticeDisplayDuration: .seconds(2))
    let controller = makeController(configuration: configuration)
    var machine = SessionStateMachine()
    let t0 = clock.now

    machine.start(at: t0)
    machine.stopRecordingAtBufferLimit()
    controller.update(from: machine)
    #expect(
      controller.presentation
        == HUDPresentation(HUDContent(status: .recognizing, notice: .audioBufferLimitReached)))

    _ = try machine.handle(event(machine, .recognitionCompleted))
    _ = try machine.handle(event(machine, .refinementCompleted))
    controller.update(from: machine)
    clock.advance(by: .seconds(1))
    _ = try machine.handle(event(machine, .insertionCompleted))
    controller.update(from: machine)

    let lingering = HUDPresentation(HUDContent(status: nil, notice: .audioBufferLimitReached))
    #expect(controller.presentation == lingering)
    #expect(scheduler.deadline == t0 + .seconds(3))

    // 予約より早く呼ばれても消さない
    clock.advance(by: .seconds(1))
    scheduler.fire()
    #expect(controller.presentation == lingering)
    #expect(scheduler.deadline == t0 + .seconds(3))

    clock.advance(by: .seconds(1))
    scheduler.fire()
    #expect(controller.presentation == nil)
    #expect(presenter.calls.last == .hide)
    #expect(scheduler.deadline == nil)
  }

  @Test("REC-03: 失敗の表示時間が過ぎたら1回だけ知らせ、失敗の表示を終えたら隠す")
  func errorDisplayExpires() throws {
    let configuration = try HUDConfiguration(
      errorDisplayDuration: .seconds(3), limitNoticeDisplayDuration: .seconds(2))
    let controller = makeController(configuration: configuration)
    var machine = SessionStateMachine()
    let t0 = clock.now
    var expiredCount = 0
    controller.onErrorDisplayExpired = {
      expiredCount += 1
    }

    machine.start(at: t0)
    _ = try machine.handle(event(machine, .failed))
    controller.update(from: machine)
    #expect(controller.presentation == (try presentation(.failed(.recording))))
    #expect(scheduler.deadline == t0 + .seconds(3))

    clock.advance(by: .seconds(3))
    scheduler.fire()
    #expect(expiredCount == 1)
    // 失敗の表示を終えるまでは表示を続ける。同じ状態を反映し直しても再び知らせない
    controller.update(from: machine)
    #expect(expiredCount == 1)
    #expect(controller.presentation == (try presentation(.failed(.recording))))
    #expect(scheduler.deadline == nil)

    machine.dismissError()
    controller.update(from: machine)
    #expect(controller.presentation == nil)
    #expect(presenter.calls.last == .hide)
  }

  @Test("REC-03: 失敗の表示時間の経過を受けて同期的に失敗の表示を終えてもよい")
  func errorDismissedSynchronouslyFromCallback() throws {
    let controller = makeController()
    var machine = SessionStateMachine()

    machine.start(at: clock.now)
    _ = try machine.handle(event(machine, .failed))
    controller.update(from: machine)
    controller.onErrorDisplayExpired = { [controller] in
      machine.dismissError()
      controller.update(from: machine)
    }

    clock.advance(by: HUDConfiguration.defaultErrorDisplayDuration)
    scheduler.fire()

    #expect(controller.presentation == nil)
    #expect(presenter.calls.last == .hide)
    #expect(scheduler.deadline == nil)
  }

  @Test("REC-03: 失敗の表示中に次のセッションが始まったら、その失敗の期限では知らせない")
  func newSessionReplacesErrorDeadline() throws {
    let controller = makeController()
    var expiredCount = 0
    controller.onErrorDisplayExpired = {
      expiredCount += 1
    }
    var machine = SessionStateMachine()

    machine.start(at: clock.now)
    _ = try machine.handle(event(machine, .failed))
    controller.update(from: machine)
    machine.cancel()
    controller.update(from: machine)
    #expect(scheduler.deadline == nil)

    machine.start(at: clock.now)
    controller.update(from: machine)
    clock.advance(by: HUDConfiguration.defaultErrorDisplayDuration)
    scheduler.fire()

    #expect(expiredCount == 0)
    #expect(controller.presentation == (try presentation(.recording)))
  }

  @Test("REC-03: 失敗の表示時間が過ぎてから初めて反映したときは、その場で知らせる")
  func errorAlreadyExpiredOnUpdate() throws {
    let controller = makeController()
    var expiredCount = 0
    controller.onErrorDisplayExpired = {
      expiredCount += 1
    }
    var machine = SessionStateMachine()
    machine.start(at: clock.now)
    _ = try machine.handle(event(machine, .failed))
    controller.update(from: machine)

    clock.advance(by: HUDConfiguration.defaultErrorDisplayDuration + .seconds(1))
    controller.update(from: machine)

    #expect(expiredCount == 1)
    #expect(scheduler.deadline == nil)
  }

  @Test("REC-03: 知らせを受けた側が失敗の表示を終えずに反映し直しても、繰り返し知らせない")
  func errorExpiryNotRepeatedWithoutDismiss() throws {
    let controller = makeController()
    var machine = SessionStateMachine()
    machine.start(at: clock.now)
    _ = try machine.handle(event(machine, .failed))
    controller.update(from: machine)
    var expiredCount = 0
    controller.onErrorDisplayExpired = { [controller] in
      expiredCount += 1
      controller.update(from: machine)
    }

    clock.advance(by: HUDConfiguration.defaultErrorDisplayDuration)
    scheduler.fire()

    #expect(expiredCount == 1)
    #expect(controller.presentation == (try presentation(.failed(.recording))))
  }

  @Test("REC-05: 通知を残している間に次のセッションを始めたら、通知と予約を消す")
  func newSessionClearsLingeringNotice() throws {
    let controller = makeController()
    var machine = SessionStateMachine()
    machine.start(at: clock.now)
    machine.stopRecordingAtBufferLimit()
    _ = try machine.handle(event(machine, .recognitionCompleted))
    _ = try machine.handle(event(machine, .refinementCompleted))
    controller.update(from: machine)
    _ = try machine.handle(event(machine, .insertionCompleted))
    controller.update(from: machine)
    #expect(scheduler.deadline != nil)

    machine.start(at: clock.now)
    controller.update(from: machine)

    #expect(controller.presentation == (try presentation(.recording)))
    #expect(scheduler.deadline == nil)
  }

  @Test("REC-05: 上限到達の後にキャンセルしたら、通知を残さずに隠す")
  func cancelAfterLimitHides() throws {
    let controller = makeController()
    var machine = SessionStateMachine()
    machine.start(at: clock.now)
    machine.stopRecordingAtBufferLimit()
    controller.update(from: machine)

    machine.cancel()
    controller.update(from: machine)

    #expect(controller.presentation == nil)
    #expect(presenter.calls.last == .hide)
    #expect(scheduler.deadline == nil)
  }

  @Test("AC-16: 整形中に退避を反映したらすぐ表示を更新し、挿入完了後も通知を残す")
  func refinementFallbackUpdatesPresentation() throws {
    let configuration = try HUDConfiguration(
      errorDisplayDuration: .seconds(5), limitNoticeDisplayDuration: .seconds(2))
    let controller = makeController(configuration: configuration)
    var machine = SessionStateMachine()
    let t0 = clock.now

    machine.start(at: t0)
    machine.stopRecordingAtBufferLimit()
    _ = try machine.handle(event(machine, .recognitionCompleted))
    controller.update(from: machine)
    let session = try #require(machine.activeSession).id

    controller.recordRefinementFallback(.timeout, for: session)
    let both: [HUDNotice] = [.audioBufferLimitReached, .refinementFellBack(.timeout)]
    #expect(
      presenter.calls.last
        == .show(
          try #require(
            HUDPresentation(
              HUDContent(status: .refining, notices: both)))))

    _ = try machine.handle(event(machine, .refinementCompleted))
    controller.update(from: machine)
    _ = try machine.handle(event(machine, .insertionCompleted))
    controller.update(from: machine)
    #expect(controller.presentation == HUDPresentation(HUDContent(status: nil, notices: both)))
    #expect(scheduler.deadline == t0 + .seconds(2))
  }

  @Test("AC-16: 整形中でないセッションの退避では表示を変えない")
  func refinementFallbackIgnoredOutsideRefining() throws {
    let controller = makeController()
    var machine = SessionStateMachine()
    machine.start(at: clock.now)
    controller.update(from: machine)
    let calls = presenter.calls

    controller.recordRefinementFallback(.timeout, for: try #require(machine.activeSession).id)

    #expect(presenter.calls == calls)
  }

  // MARK: - Realtime Preview（2.2節, AC-03）

  @Test("AC-03: 録音中・認識中は渡した認識テキストを表示し、整形へ進んだら捨てる")
  func showsTranscriptWhileRecognizing() throws {
    let controller = makeController()
    var machine = SessionStateMachine()
    machine.start(at: clock.now)
    controller.update(from: machine)
    let session = try #require(machine.activeSession?.id)

    let first = HUDTranscript(confirmedText: "", provisionalText: "きょう")
    controller.updateTranscript(first, for: session)
    #expect(controller.presentation?.transcript == first)

    machine.stopRecording(at: clock.now)
    controller.update(from: machine)
    // 認識中も残す
    #expect(controller.presentation?.transcript == first)
    let second = HUDTranscript(confirmedText: "今日は", provisionalText: "")
    controller.updateTranscript(second, for: session)
    #expect(controller.presentation?.transcript == second)

    _ = try machine.handle(event(machine, .recognitionCompleted))
    controller.update(from: machine)
    #expect(controller.presentation == (try presentation(.refining)))
    // 整形へ進んだ後に遅れて届いても表示しない
    controller.updateTranscript(second, for: session)
    #expect(controller.presentation == (try presentation(.refining)))
  }

  @Test("AC-03: 別のセッションの認識テキストは表示せず、次のセッションに前の発話を残さない")
  func dropsTranscriptOfOtherSession() throws {
    let controller = makeController()
    var machine = SessionStateMachine()
    machine.start(at: clock.now)
    controller.update(from: machine)
    let first = try #require(machine.activeSession?.id)
    controller.updateTranscript(
      HUDTranscript(confirmedText: "前の発話", provisionalText: ""), for: first)

    _ = machine.cancel()
    controller.update(from: machine)
    machine.start(at: clock.now)
    controller.update(from: machine)
    #expect(controller.presentation == (try presentation(.recording)))

    controller.updateTranscript(
      HUDTranscript(confirmedText: "遅れて届いた", provisionalText: ""), for: first)
    #expect(controller.presentation == (try presentation(.recording)))
  }

  private func makeController(configuration: HUDConfiguration = HUDConfiguration())
    -> HUDController
  {
    HUDController(
      configuration: configuration, presenter: presenter, scheduler: scheduler,
      now: { [clock] in clock.now })
  }

  private func presentation(_ status: HUDStatus) throws -> HUDPresentation {
    try #require(HUDPresentation(HUDContent(status: status, notice: nil)))
  }

  private func event(_ machine: SessionStateMachine, _ kind: SessionEvent.Kind) throws
    -> SessionEvent
  {
    SessionEvent(token: try #require(machine.currentToken), kind: kind)
  }
}

/// 手動で進める時刻
@MainActor
final class ManualClock {
  private(set) var now = ContinuousClock.now

  func advance(by duration: Duration) {
    now = now.advanced(by: duration)
  }
}

/// 表示・非表示の依頼を記録する Stub
@MainActor
final class RecordingPresenter: HUDPresenting {
  enum Call: Equatable {
    case show(HUDPresentation)
    case hide
  }

  private(set) var calls: [Call] = []

  func show(_ presentation: HUDPresentation) {
    calls.append(.show(presentation))
  }

  func hide() {
    calls.append(.hide)
  }
}

/// 予約を保持し、テストから発火させる Stub
@MainActor
final class ManualScheduler: HUDRefreshScheduling {
  private(set) var deadline: ContinuousClock.Instant?
  private var action: (@MainActor () -> Void)?

  func schedule(at deadline: ContinuousClock.Instant?, _ action: @escaping @MainActor () -> Void) {
    self.deadline = deadline
    self.action = deadline == nil ? nil : action
  }

  /// 予約した処理を、時刻にかかわらず呼ぶ（タイマーの早い発火も再現する）
  func fire() {
    let action = action
    deadline = nil
    self.action = nil
    action?()
  }
}
