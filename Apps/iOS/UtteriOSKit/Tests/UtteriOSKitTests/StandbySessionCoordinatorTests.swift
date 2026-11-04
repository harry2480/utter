import Foundation
import Synchronization
import Testing
import UtterCore
import UtterPersistence

@testable import UtteriOSKit

/// 待機セッションの調停（iOS-04〜06, iAC-03・11）。
/// App Group・オーディオセッション・録音は差し替え、OS の API を使わずに確かめる。
@MainActor
struct StandbySessionCoordinatorTests {
  private let start = Date(timeIntervalSince1970: 1_800_000_000)
  private let session = SessionID()
  private let signals = StubStandbySignals()
  private let audio = StubStandbyAudioSession()
  private let capture = StubStandbyCapture()
  /// テスト中に進める現在時刻
  private let clock = TestDate(Date(timeIntervalSince1970: 1_800_000_000))

  private func coordinator(
    _ configuration: StandbySessionConfiguration = StandbySessionConfiguration()
  ) -> StandbySessionCoordinator {
    let clock = clock
    return StandbySessionCoordinator(
      signals: signals, audio: audio, capture: capture, configuration: configuration,
      date: { clock.now })
  }

  private func command(
    _ sequence: Int64, _ action: StandbyCommand.Action, _ session: SessionID? = nil,
    at offset: TimeInterval = 0
  ) -> StandbyCommand {
    StandbyCommand(
      sequence: sequence, action: action, sessionID: session ?? self.session,
      issuedAt: start.addingTimeInterval(offset))
  }

  /// 待機を始めて、合図を1つ届ける
  private func standby(
    _ configuration: StandbySessionConfiguration = StandbySessionConfiguration()
  ) async -> StandbySessionCoordinator {
    let coordinator = coordinator(configuration)
    #expect(await coordinator.startStandby())
    return coordinator
  }

  private func advance(to offset: TimeInterval) {
    clock.set(start.addingTimeInterval(offset))
  }

  @Test("iOS-04: 待機を始めると、オーディオセッションを保ち、マイクの入力をミュートして状態を知らせる")
  func startStandbyMutesAndPublishes() async {
    let coordinator = await standby()

    #expect(coordinator.isStandingBy)
    #expect(coordinator.hostPhase == .standby)
    #expect(audio.beganStandbyCount == 1)
    #expect(audio.isInputMuted == true)
    #expect(await signals.savedPhases() == [.standby])
  }

  @Test("iOS-04: 待機を始める前に書かれていた合図は、処理済みとして実行しない")
  func pendingCommandBeforeStandbyIgnored() async {
    await signals.setCommand(command(1, .start))

    let coordinator = await standby()
    await coordinator.poll()

    #expect(capture.begun.isEmpty)
    #expect(coordinator.hostPhase == .standby)
    #expect(audio.isInputMuted == true)
  }

  @Test("iOS-04: オーディオセッションを確保できなければ待機を始めない")
  func startStandbyFailsWithoutAudioSession() async {
    audio.failsToBeginStandby = true
    let coordinator = coordinator()

    #expect(await coordinator.startStandby() == false)
    #expect(!coordinator.isStandingBy)
    #expect(coordinator.hostPhase == .off)
    #expect(await signals.savedPhases().isEmpty)
  }

  @Test("iAC-11: 開始の合図で録音を始めてミュートを外し、停止の合図で処理中→結果の状態を知らせる")
  func startAndStopCommand() async {
    let coordinator = await standby()

    await signals.setCommand(command(1, .start))
    advance(to: 0.1)
    await coordinator.poll()

    #expect(capture.begun == [session])
    #expect(audio.isInputMuted == false)
    #expect(coordinator.hostPhase == .recording)

    await signals.setCommand(command(2, .stop, at: 3))
    advance(to: 3)
    await coordinator.poll()

    #expect(capture.finished == [session])
    // 録音を止めたらミュートに戻す
    #expect(audio.isInputMuted == true)
    #expect(coordinator.hostPhase == .done)
    #expect(coordinator.failure == nil)
    // 認識・整形に時間がかかるため、処理中を先に知らせてから結果を知らせる
    #expect(await signals.savedPhases() == [.standby, .recording, .processing, .done])
  }

  @Test("iOS-04: 認識・整形・保存に失敗したら、理由を添えて失敗を知らせる")
  func processingFailurePublished() async {
    capture.failure = .processingFailed
    let coordinator = await standby()

    await signals.setCommand(command(1, .start))
    await coordinator.poll()
    await signals.setCommand(command(2, .stop))
    await coordinator.poll()

    #expect(coordinator.hostPhase == .failed)
    #expect(coordinator.failure == .processingFailed)
    #expect(await signals.savedFailures().last == .processingFailed)
  }

  @Test("iOS-06: 取り消しの合図が届いたら録音を捨てて、ミュートに戻す")
  func cancelCommandAbandonsCapture() async {
    let coordinator = await standby()

    await signals.setCommand(command(1, .start))
    await coordinator.poll()
    await signals.setCommand(command(2, .cancel))
    await coordinator.poll()

    #expect(capture.abandoned == [session])
    #expect(capture.finished.isEmpty)
    #expect(audio.isInputMuted == true)
    #expect(coordinator.hostPhase == .failed)
    #expect(coordinator.failure == .keyboardDismissed)
  }

  @Test("iOS-06: キーボードの生存の印が途絶えたら録音を捨てる")
  func heartbeatLostAbandonsCapture() async {
    let coordinator = await standby(
      StandbySessionConfiguration(keyboardHeartbeatTimeout: .seconds(5)))

    await signals.setCommand(command(1, .start))
    await coordinator.poll()
    await signals.setHeartbeat(KeyboardHeartbeat(sessionID: session, at: start))

    advance(to: 6)
    await coordinator.poll()

    #expect(capture.abandoned == [session])
    #expect(coordinator.failure == .keyboardHeartbeatLost)
  }

  @Test("iOS-06: 停止の合図が届かないまま録音の上限を超えたら捨てる")
  func captureLimitAbandonsCapture() async {
    let coordinator = await standby(
      StandbySessionConfiguration(maxCaptureDuration: .seconds(120)))

    await signals.setCommand(command(1, .start))
    await coordinator.poll()
    // 生存の印は届き続けているが、停止の合図が来ない
    await signals.setHeartbeat(KeyboardHeartbeat(sessionID: session, at: start))

    advance(to: 121)
    await signals.setHeartbeat(
      KeyboardHeartbeat(sessionID: session, at: start.addingTimeInterval(121)))
    await coordinator.poll()

    #expect(capture.abandoned == [session])
    #expect(coordinator.failure == .captureLimitExceeded)
  }

  @Test("iOS-04: 無操作が続いたら待機を終え、オーディオセッションを手放す")
  func idleTimeoutEndsStandby() async {
    let coordinator = await standby(StandbySessionConfiguration(idleTimeout: .seconds(300)))

    advance(to: 301)
    await coordinator.poll()

    #expect(audio.endedStandbyCount == 1)
    #expect(!coordinator.isStandingBy)
    #expect(coordinator.hostPhase == .off)
    #expect(await signals.savedPhases().last == .off)
  }

  @Test("iOS-04: 利用者が録音中に待機を終えたら、録音を捨ててオーディオセッションを手放す")
  func endStandbyWhileRecording() async {
    let coordinator = await standby()

    await signals.setCommand(command(1, .start))
    await coordinator.poll()
    await coordinator.endStandby()

    #expect(capture.abandoned == [session])
    #expect(audio.endedStandbyCount == 1)
    #expect(coordinator.hostPhase == .off)
  }

  @Test("iOS-PERF-03: 録音中にオーディオの割り込みが始まったら録音を捨てる")
  func interruptionAbandonsCapture() async {
    let coordinator = await standby()

    await signals.setCommand(command(1, .start))
    await coordinator.poll()
    await coordinator.interruptionBegan()

    #expect(capture.abandoned == [session])
    #expect(coordinator.failure == .interrupted)
    // 待機は続ける（オーディオセッションは手放さない）
    #expect(audio.endedStandbyCount == 0)
    #expect(coordinator.isStandingBy)
  }

  @Test("iOS-04: 合図を読めなくても、録音の上限と生存の印の途絶は確かめる")
  func checksLimitsWhenCommandUnreadable() async {
    let coordinator = await standby(
      StandbySessionConfiguration(keyboardHeartbeatTimeout: .seconds(5)))

    await signals.setCommand(command(1, .start))
    await coordinator.poll()
    #expect(capture.begun == [session])

    // 端末のロック中などで読めない
    await signals.setReadFailure(true)
    advance(to: 6)
    await coordinator.poll()

    #expect(capture.abandoned == [session])
    #expect(coordinator.failure == .keyboardHeartbeatLost)
  }

  @Test("iOS-04: 状態を書けなくても待機は続ける")
  func keepsStandbyWhenHostStateUnwritable() async {
    await signals.setWriteFailure(true)
    let coordinator = await standby()

    #expect(coordinator.isStandingBy)
    #expect(coordinator.hostPhase == .standby)

    await signals.setCommand(command(1, .start))
    await coordinator.poll()

    #expect(capture.begun == [session])
    #expect(coordinator.hostPhase == .recording)
  }

  @Test("iOS-04: 待機中は、処理がなくても状態を書き直して本体アプリが生きていることを知らせる")
  func republishesHostStateWhileIdle() async {
    let coordinator = await standby()

    advance(to: 5)
    await coordinator.poll()

    let saved = await signals.savedStates()
    #expect(saved.count == 2)
    #expect(saved.last?.phase == .standby)
    #expect(saved.last?.updatedAt == start.addingTimeInterval(5))
  }

  @Test("iOS-04: 始める途中に重ねて始める操作を受けても、オーディオセッションを二重に確保しない")
  func startStandbyIgnoredWhileStarting() async {
    await signals.setHoldsLoad(true)
    let coordinator = coordinator()

    let starting = Task { await coordinator.startStandby() }
    // 合図の読み直しで止まっている間に、もう一度始める操作を受ける
    #expect(await waitUntil { audio.beganStandbyCount == 1 })
    #expect(await coordinator.startStandby())
    #expect(audio.beganStandbyCount == 1)

    await signals.releaseLoad()
    #expect(await starting.value)
    #expect(coordinator.isStandingBy)
    #expect(coordinator.hostPhase == .standby)
  }

  @Test("iOS-04: 始める途中に待機を終える操作を受けたら、始めたうえで終える")
  func endStandbyRequestedWhileStarting() async {
    await signals.setHoldsLoad(true)
    let coordinator = coordinator()

    let starting = Task { await coordinator.startStandby() }
    #expect(await waitUntil { audio.beganStandbyCount == 1 })
    await coordinator.endStandby()

    await signals.releaseLoad()
    #expect(await starting.value)
    #expect(audio.endedStandbyCount == 1)
    #expect(!coordinator.isStandingBy)
    #expect(coordinator.hostPhase == .off)
  }

  @Test("iOS-04: 待機していないときは、合図を読まない")
  func pollIgnoredWhileOff() async {
    let coordinator = coordinator()
    await signals.setCommand(command(1, .start))

    await coordinator.poll()

    #expect(capture.begun.isEmpty)
    #expect(await signals.savedPhases().isEmpty)
  }
}

/// 進められる実時刻。待機セッションの時間の判定に使う
final class TestDate: Sendable {
  private let current: Mutex<Date>

  init(_ now: Date) {
    current = Mutex(now)
  }

  var now: Date { current.withLock { $0 } }

  func set(_ now: Date) {
    current.withLock { $0 = now }
  }
}

/// App Group の代わり。合図・生存の印をテストから置き、書かれた状態を記録する。
actor StubStandbySignals: StandbySessionSignals {
  struct AccessDenied: Error {}

  private var command: StandbyCommand?
  private var heartbeat: KeyboardHeartbeat?
  private var states: [StandbyHostState] = []
  private var readFails = false
  private var writeFails = false
  private var holdsLoad = false
  private var loadGate: CheckedContinuation<Void, Never>?

  func setCommand(_ command: StandbyCommand) {
    self.command = command
  }

  func setHeartbeat(_ heartbeat: KeyboardHeartbeat) {
    self.heartbeat = heartbeat
  }

  /// 設定すると、合図・生存の印を読めなくする（端末のロック中など）
  func setReadFailure(_ fails: Bool) {
    readFails = fails
  }

  /// 設定すると、状態を書けなくする
  func setWriteFailure(_ fails: Bool) {
    writeFails = fails
  }

  func savedStates() -> [StandbyHostState] { states }
  func savedPhases() -> [StandbyHostState.Phase] { states.map(\.phase) }
  func savedFailures() -> [StandbyFailure] { states.compactMap(\.failure) }

  /// 設定すると、合図の読みを `releaseLoad()` まで止める（開始の途中の割り込みを試す）
  func setHoldsLoad(_ holds: Bool) {
    holdsLoad = holds
  }

  /// 止めていた合図の読みを進める
  func releaseLoad() {
    let gate = loadGate
    loadGate = nil
    holdsLoad = false
    gate?.resume()
  }

  func loadCommand() async throws -> StandbyCommand? {
    if readFails { throw AccessDenied() }
    if holdsLoad {
      await withCheckedContinuation { loadGate = $0 }
    }
    return command
  }

  func loadHeartbeat() throws -> KeyboardHeartbeat? {
    if readFails { throw AccessDenied() }
    return heartbeat
  }

  func saveHostState(_ state: StandbyHostState) throws {
    if writeFails { throw AccessDenied() }
    states.append(state)
  }
}

/// 待機中のオーディオセッションの代わり。
@MainActor
final class StubStandbyAudioSession: StandbyAudioSession {
  struct Unavailable: Error {}

  var failsToBeginStandby = false
  private(set) var beganStandbyCount = 0
  private(set) var endedStandbyCount = 0
  private(set) var isInputMuted: Bool?

  func beginStandby() throws {
    if failsToBeginStandby { throw Unavailable() }
    beganStandbyCount += 1
  }

  func endStandby() {
    endedStandbyCount += 1
  }

  func setInputMuted(_ muted: Bool) {
    isInputMuted = muted
  }
}

/// 録音と、その後の認識・整形・保存の代わり。
@MainActor
final class StubStandbyCapture: StandbyCapturing {
  /// `finishCapture` が返す失敗の理由
  var failure: StandbyFailure?
  private(set) var begun: [SessionID] = []
  private(set) var finished: [SessionID] = []
  private(set) var abandoned: [SessionID] = []

  func beginCapture(_ sessionID: SessionID) {
    begun.append(sessionID)
  }

  func finishCapture(_ sessionID: SessionID) async -> StandbyFailure? {
    finished.append(sessionID)
    return failure
  }

  func abandonCapture(_ sessionID: SessionID) {
    abandoned.append(sessionID)
  }
}
