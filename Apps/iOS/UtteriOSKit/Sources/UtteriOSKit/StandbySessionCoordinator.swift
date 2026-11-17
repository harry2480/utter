import Foundation
import Observation
import UtterCore
import UtterPersistence

/// 待機セッションの合図・状態・生存の印の置き場所（iOS-04）。本番は UtterPersistence の `StandbySessionStore`。
///
/// 合図のファイルを正とし、プロセス間の通知は読み直しのきっかけにだけ使う。
public protocol StandbySessionSignals: Sendable {
  /// キーボードが最後に書いた合図。なければ `nil`
  func loadCommand() async throws -> StandbyCommand?
  /// 録音中にキーボードが書く生存の印。なければ `nil`
  func loadHeartbeat() async throws -> KeyboardHeartbeat?
  /// キーボードに知らせる本体アプリの状態
  func saveHostState(_ state: StandbyHostState) async throws
}

extension StandbySessionStore: StandbySessionSignals {}

/// 待機中のオーディオセッション（iOS-04, iOS-PERF-02, iOS-PERF-03）。
/// 本番は Apps/iOS の AVAudioSession のアダプター。
@MainActor
public protocol StandbyAudioSession: AnyObject {
  /// 待機を始める（オーディオセッションを保つ）。確保できなければ投げる
  func beginStandby() throws
  /// 待機を終える（オーディオセッションを手放す）
  func endStandby()
  /// マイクの入力をミュートする。合図が届くまでは `true`（待機中にマイクの使用表示を出さない, iOS-04）
  func setInputMuted(_ muted: Bool)
  /// 割り込みの終わり・メディアサービスのリセットの後に、待機のオーディオセッションを取り戻す（iOS-PERF-03, #248）。
  /// 取り戻せなければ `false`。そのときも片付けは `endStandby()` に任せる（保ったまま返し、ミュートを残さない）
  func restoreStandby(after disruption: StandbyAudioDisruption) -> Bool
}

/// 待機のオーディオを取り戻すきっかけ（iOS-PERF-03, #248）
public enum StandbyAudioDisruption: Hashable, Sendable {
  /// 着信などの割り込みが終わった
  case interruptionEnded
  /// メディアサービスがリセットされた。オーディオのオブジェクトはすべて無効になっている
  case mediaServicesReset
}

/// 合図を受けた録音と、その後の認識・整形・共有結果への保存（iOS-04）。
@MainActor
public protocol StandbyCapturing: AnyObject {
  /// 録音を始める
  func beginCapture(_ sessionID: SessionID)
  /// 録音を止めて、認識・整形・共有結果への保存まで進める
  /// - Returns: 保存できなければ理由。保存できたら `nil`
  func finishCapture(_ sessionID: SessionID) async -> StandbyFailure?
  /// 録音を止めて捨てる。認識の結果も保存しない（iOS-06）
  func abandonCapture(_ sessionID: SessionID)
}

/// 本体アプリの待機セッション（iOS-04〜06, iAC-03・11）。
///
/// `StandbySessionMachine` が決めた処理を、オーディオセッション・録音・App Group への書き込みにつなぐ。
/// OS の API は protocol 越しに分けてあり、この型はテストできる。
///
/// 呼ぶ側（Apps/iOS）は次のようにする。
/// - 利用者が待機を始める・終えるとき `startStandby()` / `endStandby()`
/// - 合図のプロセス間の通知を受けたときと、定期的（`StandbyHostState.heartbeatTimeout` より短い間隔）に `poll()`。
///   定期的に呼ぶのは、録音の上限・生存の印の途絶・無操作を確かめ、本体アプリが生きていることを書き直すため
/// - オーディオの割り込みが始まったとき `interruptionBegan()`、終わったとき `interruptionEnded()`、
///   メディアサービスがリセットされたとき `mediaServicesWereReset()`（iOS-PERF-03, #248）。
///   待機を始める途中に届いたものも渡す（始めた後に取り戻す）
@MainActor
@Observable
public final class StandbySessionCoordinator {
  /// キーボードに知らせている状態。画面にも使う
  public private(set) var hostPhase: StandbyHostState.Phase = .off
  /// 直近で録音を捨てた・処理に失敗した理由
  public private(set) var failure: StandbyFailure?
  /// 録音中で、キーボードが離れている（閉じても録音を続ける設定のとき, #267）
  public private(set) var isRecordingDetached = false
  /// 割り込みの後などに待機のオーディオを取り戻せず、待機を終えた（#248）。次に待機を始めるまで残す
  public private(set) var endedByAudioLoss = false

  @ObservationIgnored private var machine: StandbySessionMachine
  @ObservationIgnored private let signals: any StandbySessionSignals
  @ObservationIgnored private let audio: any StandbyAudioSession
  @ObservationIgnored private let capture: any StandbyCapturing
  @ObservationIgnored private let date: @Sendable () -> Date
  /// 停止後の挿入のしかた（iOS-05）。キーボードが従うため、状態に載せて知らせる
  @ObservationIgnored private let insertionMode: @MainActor () -> StandbyInsertionMode
  /// 待機を始める途中か。状態機械がまだ待機していない（`.off`）間だけ真にする
  @ObservationIgnored private var isStarting = false
  /// 始める途中に待機を終える操作を受けたか。始めたあとに終える
  @ObservationIgnored private var endRequestedWhileStarting = false
  /// 始める途中に、オーディオを取り戻すきっかけを受けたか。始めたあとに取り戻す（リセットを優先する）
  @ObservationIgnored private var restoreRequestedWhileStarting: StandbyAudioDisruption?
  /// 直前の状態の書き込み。書いた順に完了させ、古い状態で上書きしないためにつなぐ
  @ObservationIgnored private var writing: Task<Void, Never>?

  /// - Parameters:
  ///   - signals: 合図・状態・生存の印の置き場所（App Group）
  ///   - audio: 待機中のオーディオセッション
  ///   - capture: 録音と、その後の認識・整形・保存
  ///   - configuration: 無操作で終える時間・録音の上限など
  ///   - insertionMode: 停止後の挿入のしかた。状態を書くたびに読む
  ///   - date: 実時刻。テストでは固定できる
  public init(
    signals: any StandbySessionSignals,
    audio: any StandbyAudioSession,
    capture: any StandbyCapturing,
    configuration: StandbySessionConfiguration = StandbySessionConfiguration(),
    insertionMode: @escaping @MainActor () -> StandbyInsertionMode = { .automatic },
    date: @escaping @Sendable () -> Date = { Date() }
  ) {
    machine = StandbySessionMachine(configuration: configuration)
    self.signals = signals
    self.audio = audio
    self.capture = capture
    self.insertionMode = insertionMode
    self.date = date
  }

  /// 待機中か（待機していなければ `false`）
  public var isStandingBy: Bool { machine.phase != .off }

  /// 無操作で終える時間などを変える。待機していないときだけ反映する（待機の途中では変えない）
  public func updateConfiguration(_ configuration: StandbySessionConfiguration) {
    guard machine.phase == .off, !isStarting else { return }
    machine.configuration = configuration
  }

  /// 利用者が待機を始める（iOS-04）。マイクの入力は合図が届くまでミュートする
  /// - Returns: 始められたら `true`。オーディオセッションを確保できなければ `false`
  @discardableResult
  public func startStandby() async -> Bool {
    // 始める途中（合図の読み直しの待ち）に重ねて呼ばれても、オーディオセッションを二重に確保しない
    guard machine.phase == .off, !isStarting else { return true }
    isStarting = true
    endRequestedWhileStarting = false
    restoreRequestedWhileStarting = nil
    endedByAudioLoss = false
    do {
      try audio.beginStandby()
    } catch {
      isStarting = false
      return false
    }
    audio.setInputMuted(true)
    // 待機を始める前に書かれていた合図は、処理済みとして実行しない
    let pending = try? await signals.loadCommand()
    machine.startStandby(pendingCommand: pending, at: date())
    // 状態機械が待機に移ったら、もう始める途中ではない。この後に受けた終える操作は、
    // 状態の書き込みを待たずにそのまま効く
    isStarting = false
    failure = nil
    // 読み直しを待つ間に待機を終える操作を受けていたら、始めたうえで終える（要求を落とさない）
    guard !endRequestedWhileStarting else {
      endRequestedWhileStarting = false
      await apply(machine.endStandby(at: date()))
      return true
    }
    // 読み直しを待つ間に割り込みの終わり・リセットを受けていたら、始めたうえで取り戻す
    if let disruption = restoreRequestedWhileStarting {
      restoreRequestedWhileStarting = nil
      guard audio.restoreStandby(after: disruption) else {
        await endForAudioLoss()
        return true
      }
    }
    await writeHostState()
    return true
  }

  /// 利用者が待機を終える。録音中なら捨てる
  public func endStandby() async {
    // 状態機械がまだ待機していない（始める途中）ときだけ、覚えておいて始めたあとに終える
    guard !isStarting else {
      endRequestedWhileStarting = true
      return
    }
    await apply(machine.endStandby(at: date()))
  }

  /// 合図を読み直し、録音の上限・生存の印の途絶・無操作を確かめる。
  /// 合図を読めなくても（端末のロック中など）確かめは行う
  public func poll() async {
    guard machine.phase != .off else { return }
    // 読み込みを先に終え、状態の変更から効果の実行まで待ちを挟まない（別の poll に追い越されないため）
    // 時刻は読み込みの前に取る。読み込みが遅れても、読んだ生存の印が古く見えて録音を捨てないため
    let now = date()
    let command = try? await signals.loadCommand()
    let heartbeat = try? await signals.loadHeartbeat()
    var effects: [StandbySessionEffect] = []
    if let command {
      effects += machine.receive(command, at: now)
    }
    effects += machine.tick(heartbeat: heartbeat, at: now)
    await apply(effects)
  }

  /// 着信などのオーディオの割り込みが始まった（iOS-PERF-03）。録音中なら捨てる
  public func interruptionBegan() async {
    await apply(machine.interruptionBegan(at: date()))
  }

  /// 着信などのオーディオの割り込みが終わった。待機のオーディオを取り戻し、取り戻せなければ待機を終える（#248）。
  ///
  /// 割り込みの終わりの `shouldResume` は見ない。待機は他のアプリの音と混ぜる設定（`mixWithOthers`）で、取り戻しても
  /// 他のアプリの音を止めず、待機を保つには入力を開き続ける必要があるため。取り戻せなければ待機を終えて知らせる
  public func interruptionEnded() async {
    await restore(after: .interruptionEnded)
  }

  /// メディアサービスがリセットされた。録音中なら捨て（割り込みと同じ扱い）、待機のオーディオを作り直す。
  /// 作り直せなければ待機を終える（#248）
  public func mediaServicesWereReset() async {
    await restore(after: .mediaServicesReset)
  }

  private func restore(after disruption: StandbyAudioDisruption) async {
    if isStarting {
      // 始める途中は、始めた後に取り戻す。リセットのほうが重い（エンジンを作り直す）ので優先する
      if restoreRequestedWhileStarting != .mediaServicesReset {
        restoreRequestedWhileStarting = disruption
      }
      return
    }
    guard machine.phase != .off else { return }
    // 録音中なら捨てると決める。リセットでは録音のオブジェクトも無効になっている。割り込みの終わりで録音中なのは、
    // 始まりの通知が届かなかったときなど。録音を続けたまま待機のエンジンを作り直さない
    var effects = machine.interruptionBegan(at: date())
    // 取り戻すまで待ちを挟まない。状態の書き込みを待つ間に開始の合図を受け、取り戻す前のオーディオで録音を始めないため
    if !audio.restoreStandby(after: disruption) {
      endedByAudioLoss = true
      effects += machine.endStandby(at: date())
    }
    await apply(effects)
  }

  private func endForAudioLoss() async {
    endedByAudioLoss = true
    await apply(machine.endStandby(at: date()))
  }

  /// 端末がロックされた。録音中なら捨てる（#267）
  public func deviceLocked() async {
    guard machine.phase != .off else { return }
    await apply(machine.deviceLocked(at: date()))
  }

  /// 端末のロックが解けた。また録音を始められる
  public func deviceUnlocked() {
    machine.deviceUnlocked()
  }

  /// 状態機械が決めた処理を行い、最後に状態を書く。
  /// 処理がなくても書くのは、本体アプリが待機を続けていることをキーボードに知らせるため
  private func apply(_ effects: [StandbySessionEffect]) async {
    for effect in effects {
      switch effect {
      case .beginCapture(let sessionID):
        failure = nil
        // 合図を受けてからミュートを外す（待機中はマイクの使用表示を出さない, iOS-04）
        audio.setInputMuted(false)
        capture.beginCapture(sessionID)
      case .finishCapture(let sessionID):
        audio.setInputMuted(true)
        // 認識・整形に時間がかかるため、先に処理中であることを知らせる
        await writeHostState()
        let reason = await capture.finishCapture(sessionID)
        failure = reason
        machine.finishProcessing(sessionID, failure: reason, at: date())
      case .abandonCapture(let sessionID, let reason):
        audio.setInputMuted(true)
        capture.abandonCapture(sessionID)
        failure = reason
      case .endStandby:
        audio.endStandby()
      }
    }
    await writeHostState()
  }

  /// キーボードに知らせる状態を書く。
  ///
  /// 書き込みは始めた順に完了させる。待機を始めた直後に終えたときのように書き込みが重なると、
  /// 順序が入れ替わって古い状態（`standby`）が最後に残りうるため（#247 のレビュー）。
  /// 書けなくても（端末のロック中など）待機は続ける。キーボードは更新が途絶えたことで気づく
  private func writeHostState() async {
    // キーボードが一度離れたセッションの結果は、設定が自動挿入でも確かめてから入れる（iOS-06, #267）
    let mode = machine.currentSessionWasDetached ? .preview : insertionMode()
    let state = machine.hostState(at: date()).with(insertionMode: mode)
    hostPhase = state.phase
    isRecordingDetached = state.isDetached
    let previous = writing
    let signals = signals
    let task = Task { @MainActor in
      await previous?.value
      try? await signals.saveHostState(state)
    }
    writing = task
    await task.value
  }
}
