import Foundation
import Testing
import UtterCore
import UtterPersistence

@testable import UtteriOSKit

struct StandbySessionMachineTests {
  private let start = Date(timeIntervalSince1970: 1_800_000_000)
  private let session = SessionID()

  private func command(
    _ sequence: Int64, _ action: StandbyCommand.Action, _ session: SessionID? = nil,
    at offset: TimeInterval = 0
  ) -> StandbyCommand {
    StandbyCommand(
      sequence: sequence, action: action, sessionID: session ?? self.session,
      issuedAt: start.addingTimeInterval(offset))
  }

  private func standby(
    _ configuration: StandbySessionConfiguration = StandbySessionConfiguration(),
    pending: StandbyCommand? = nil
  ) -> StandbySessionMachine {
    var machine = StandbySessionMachine(configuration: configuration)
    machine.startStandby(pendingCommand: pending, at: start)
    return machine
  }

  private func at(_ offset: TimeInterval) -> Date { start.addingTimeInterval(offset) }

  @Test("iAC-11: 開始→停止の合図で録音を始めて止め、保存できたら結果の状態になる")
  func startStopDone() {
    var machine = standby()

    #expect(machine.receive(command(1, .start), at: at(0.1)) == [.beginCapture(session)])
    #expect(machine.hostState(at: at(0.1)).phase == .recording)
    #expect(machine.receive(command(2, .stop, at: 3), at: at(3)) == [.finishCapture(session)])
    #expect(machine.hostState(at: at(3)).phase == .processing)

    machine.finishProcessing(session, failure: nil, at: at(4))
    let state = machine.hostState(at: at(4))
    #expect(state.phase == .done)
    #expect(state.sessionID == session)
    #expect(state.failure == nil)
  }

  @Test("iOS-04: 重複して届いた合図・処理済みより古い番号の合図は、もう一度は行わない")
  func duplicateCommandsIgnored() {
    var machine = standby()
    let first = command(10, .start)

    #expect(machine.receive(first, at: at(0)) == [.beginCapture(session)])
    #expect(machine.receive(first, at: at(0.5)).isEmpty)
    #expect(machine.receive(command(9, .stop), at: at(1)).isEmpty)
    #expect(machine.hostState(at: at(1)).phase == .recording)
  }

  @Test("iOS-04: 待機を始める前に書かれていた合図は実行しない")
  func pendingCommandBeforeStandbyIgnored() {
    let pending = command(5, .start)
    var machine = standby(pending: pending)

    #expect(machine.receive(pending, at: at(0)).isEmpty)
    #expect(machine.hostState(at: at(0)).phase == .standby)
  }

  @Test("iOS-04: 遅れて届いた開始の合図では録音を始めない。番号は処理済みにする")
  func delayedStartIgnored() {
    var machine = standby()

    #expect(machine.receive(command(1, .start, at: 0), at: at(5.5)).isEmpty)
    #expect(machine.hostState(at: at(5.5)).phase == .standby)
    #expect(machine.lastSequence == 1)
    #expect(machine.receive(command(2, .start, at: 6), at: at(6.2)) == [.beginCapture(session)])
  }

  @Test("iOS-04: 停止の合図は遅れて届いても、録音中の同じセッションなら止める")
  func delayedStopHandled() {
    var machine = standby()
    _ = machine.receive(command(1, .start), at: at(0))

    #expect(machine.receive(command(2, .stop, at: 1), at: at(4)) == [.finishCapture(session)])
  }

  @Test("iOS-04: 別のセッションの停止・取り消しでは、今の録音を止めない")
  func otherSessionStopIgnored() {
    var machine = standby()
    _ = machine.receive(command(1, .start), at: at(0))
    let other = SessionID()

    #expect(machine.receive(command(2, .stop, other), at: at(1)).isEmpty)
    #expect(machine.receive(command(3, .cancel, other), at: at(1)).isEmpty)
    #expect(machine.hostState(at: at(1)).phase == .recording)
  }

  @Test("iOS-06: 録音中にキーボードが閉じられた（取り消しの合図）ら録音を捨て、次の開始ですぐ録音できる")
  func cancelAbandonsAndRecovers() {
    var machine = standby()
    _ = machine.receive(command(1, .start), at: at(0))

    #expect(
      machine.receive(command(2, .cancel), at: at(1))
        == [.abandonCapture(session, .keyboardDismissed)])
    #expect(machine.hostState(at: at(1)).failure == .keyboardDismissed)

    let next = SessionID()
    #expect(machine.receive(command(3, .start, next, at: 2), at: at(2)) == [.beginCapture(next)])
  }

  @Test("iOS-06: 取り消しを取りこぼしたまま別のセッションの開始が届いたら、前の録音を捨ててから始める")
  func newSessionSupersedes() {
    var machine = standby()
    _ = machine.receive(command(1, .start), at: at(0))
    let next = SessionID()

    #expect(
      machine.receive(command(3, .start, next, at: 1), at: at(1)) == [
        .abandonCapture(session, .supersededBySession), .beginCapture(next),
      ])
  }

  @Test("iOS-04: 認識・整形中に届いた開始の合図では録音を始めない")
  func startWhileProcessingIgnored() {
    var machine = standby()
    _ = machine.receive(command(1, .start), at: at(0))
    _ = machine.receive(command(2, .stop), at: at(1))

    #expect(machine.receive(command(3, .start, SessionID(), at: 1.5), at: at(1.5)).isEmpty)
    #expect(machine.hostState(at: at(1.5)).phase == .processing)
  }

  @Test("iOS-06: 録音中にキーボードの生存の印が途絶えたら録音を捨てる")
  func heartbeatLostAbandons() {
    var machine = standby()
    _ = machine.receive(command(1, .start), at: at(0))

    // 印がまだ届いていなくても、録音を始めてからの時間で数える
    #expect(machine.tick(heartbeat: nil, at: at(4)).isEmpty)
    #expect(
      machine.tick(heartbeat: KeyboardHeartbeat(sessionID: session, at: at(3)), at: at(7)).isEmpty)
    #expect(
      machine.tick(heartbeat: KeyboardHeartbeat(sessionID: session, at: at(3)), at: at(8.5))
        == [.abandonCapture(session, .keyboardHeartbeatLost)])
  }

  @Test("iOS-06: 前のセッションの生存の印では、今の録音を生きているとみなさない")
  func heartbeatOfOtherSessionIgnored() {
    var machine = standby()
    _ = machine.receive(command(1, .start), at: at(0))

    #expect(
      machine.tick(heartbeat: KeyboardHeartbeat(sessionID: SessionID(), at: at(5.5)), at: at(5.5))
        == [.abandonCapture(session, .keyboardHeartbeatLost)])
  }

  @Test("iOS-06: 停止の合図が届かないまま録音の上限（既定120秒）を超えたら捨てる")
  func captureLimit() {
    var machine = standby()
    _ = machine.receive(command(1, .start), at: at(0))
    let alive = KeyboardHeartbeat(sessionID: session, at: at(120))

    #expect(machine.tick(heartbeat: alive, at: at(120)).isEmpty)
    #expect(
      machine.tick(heartbeat: KeyboardHeartbeat(sessionID: session, at: at(121)), at: at(121))
        == [.abandonCapture(session, .captureLimitExceeded)])
  }

  @Test("iOS-04: 無操作が続いたら待機を終える（既定5分）。合図を受けると数え直す")
  func idleTimeout() {
    var machine = standby()

    #expect(machine.tick(heartbeat: nil, at: at(299)).isEmpty)
    _ = machine.receive(command(1, .start, at: 299), at: at(299))
    _ = machine.receive(command(2, .stop, at: 300), at: at(300))
    machine.finishProcessing(session, failure: nil, at: at(301))

    #expect(machine.tick(heartbeat: nil, at: at(600)).isEmpty)
    #expect(machine.tick(heartbeat: nil, at: at(602)) == [.endStandby(.idleTimeout)])
    #expect(machine.hostState(at: at(602)).phase == .off)
    // 待機を終えた後の合図は扱わない
    #expect(machine.receive(command(3, .start, at: 602), at: at(602)).isEmpty)
  }

  @Test("iOS-04: 認識・整形中は無操作で待機を終えない")
  func noIdleTimeoutWhileProcessing() {
    var machine = standby()
    _ = machine.receive(command(1, .start), at: at(0))
    _ = machine.receive(command(2, .stop), at: at(1))

    #expect(machine.tick(heartbeat: nil, at: at(1_000)).isEmpty)
  }

  @Test("iOS-04: 無操作の時間を設定しなければ、無操作では終えない")
  func idleTimeoutDisabled() {
    var machine = standby(StandbySessionConfiguration(idleTimeout: nil))

    #expect(machine.tick(heartbeat: nil, at: at(100_000)).isEmpty)
  }

  @Test("iOS-PERF-03: 録音中に着信などの割り込みが始まったら録音を捨て、次の開始で録音できる")
  func interruption() {
    var machine = standby()
    #expect(machine.interruptionBegan(at: at(0)).isEmpty)
    _ = machine.receive(command(1, .start), at: at(0))

    #expect(machine.interruptionBegan(at: at(1)) == [.abandonCapture(session, .interrupted)])
    let next = SessionID()
    #expect(machine.receive(command(2, .start, next, at: 2), at: at(2)) == [.beginCapture(next)])
  }

  @Test("iOS-04: 録音中に利用者が待機を終えたら、録音を捨ててから終える")
  func endWhileRecording() {
    var machine = standby()
    _ = machine.receive(command(1, .start), at: at(0))

    #expect(
      machine.endStandby(at: at(1)) == [
        .abandonCapture(session, .standbyEnded), .endStandby(.userRequested),
      ])
    #expect(machine.endStandby(at: at(2)).isEmpty)
  }

  @Test("iOS-04: 失敗した処理は理由つきの失敗の状態になり、別のセッションの完了の知らせは無視する")
  func processingFailure() {
    var machine = standby()
    _ = machine.receive(command(1, .start), at: at(0))
    _ = machine.receive(command(2, .stop), at: at(1))

    machine.finishProcessing(SessionID(), failure: nil, at: at(2))
    #expect(machine.hostState(at: at(2)).phase == .processing)
    machine.finishProcessing(session, failure: .noSpeech, at: at(2))
    #expect(machine.hostState(at: at(2)).failure == .noSpeech)
  }
}
