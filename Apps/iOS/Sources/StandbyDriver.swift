import AVFoundation
import Observation
import UIKit
import UtterPersistence
import UtteriOSKit

/// 本体アプリの待機セッションを動かす（iOS-04〜06）。
///
/// 画面の操作（待機の開始・終了）と、定期的な読み直し・キーボードからの通知・オーディオの割り込みを
/// `StandbySessionCoordinator` につなぐ。判断は `StandbySessionMachine` が持つ。待機している間だけ動き、
/// 待機を終えたら読み直しも通知の受信もやめる。
@MainActor
@Observable
final class StandbyDriver {
  let coordinator: StandbySessionCoordinator
  /// 待機を始められなかった（オーディオセッションを確保できなかった）
  private(set) var startFailed = false

  @ObservationIgnored private let audio: StandbyAudioSessionAdapter
  @ObservationIgnored private let preferences: StandbyPreferences
  @ObservationIgnored private let groupIdentifier: String
  @ObservationIgnored private let store: StandbySessionStore
  @ObservationIgnored private var pollTask: Task<Void, Never>?
  @ObservationIgnored private var commandObservation: StandbyDarwinObservation?
  @ObservationIgnored private var interruptionObserver: (any NSObjectProtocol)?
  @ObservationIgnored private var mediaServicesResetObserver: (any NSObjectProtocol)?
  /// 待機を始める途中か。この間は、待機していなくても観測をやめない（協調役が受けた通知を始めた後に取り戻すため）
  @ObservationIgnored private var isStarting = false
  @ObservationIgnored private var lockObserver: (any NSObjectProtocol)?
  @ObservationIgnored private var unlockObserver: (any NSObjectProtocol)?

  /// 状態を読み直す間隔。本体アプリの更新が途絶えた判定（8秒）より十分短くする
  private static let pollInterval: Duration = .seconds(1)

  init(
    coordinator: StandbySessionCoordinator, audio: StandbyAudioSessionAdapter,
    preferences: StandbyPreferences, groupIdentifier: String, store: StandbySessionStore
  ) {
    self.coordinator = coordinator
    self.audio = audio
    self.preferences = preferences
    self.groupIdentifier = groupIdentifier
    self.store = store
  }

  var isStandingBy: Bool { coordinator.isStandingBy }

  /// 利用者が待機を始める
  func start() async {
    // 始める途中に重ねて呼ばれたら何もしない（後の呼び出しが、始める途中の観測をやめないように）
    guard !coordinator.isStandingBy, !isStarting else { return }
    coordinator.updateConfiguration(preferences.sessionConfiguration)
    startFailed = false
    // 割り込みの終わりとリセットは、始める途中に届いても取りこぼさないよう先に受け始める（協調役が始めた後に取り戻す）
    beginObservingAudio()
    isStarting = true
    let started = await coordinator.startStandby()
    isStarting = false
    guard started else {
      startFailed = true
      stopObservingIfEnded()
      return
    }
    // 始める途中に終える操作を受けていた、または取り戻せなかったら、すでに終わっている
    guard coordinator.isStandingBy else {
      stopObservingIfEnded()
      return
    }
    beginObserving()
  }

  /// キーボードのマイクの操作で開かれたときに待機を始める（iOS-03・iOS-04, #267）。
  ///
  /// URL は他のアプリからも開けるため、キーボードが App Group に書いた同じ ID の要求を消費できたときだけ始める。
  /// 要求を読んだ後にも `canStart`（本体アプリで録音中・録音の準備中でない）を確かめる
  func startRequestedByKeyboard(requestID: UUID, canStart: () -> Bool) async {
    guard await store.consumeStartRequest(requestID, at: Date()), canStart() else { return }
    await start()
  }

  /// 利用者が待機を終える
  func end() async {
    await coordinator.endStandby()
    stopObservingIfEnded()
  }

  /// オーディオの割り込みとメディアサービスのリセットを受け始める（iOS-PERF-03, #248）
  private func beginObservingAudio() {
    if interruptionObserver == nil {
      interruptionObserver = NotificationCenter.default.addObserver(
        forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
      ) { [weak self] notification in
        let rawValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
        let type = rawValue.flatMap(AVAudioSession.InterruptionType.init(rawValue:))
        MainActor.assumeIsolated { self?.handleInterruption(type) }
      }
    }
    if mediaServicesResetObserver == nil {
      mediaServicesResetObserver = NotificationCenter.default.addObserver(
        forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self else { return }
          // 通知を受けたこの処理の中で、録音を捨てて取り戻すところまで進める（最初の待ちまで同期で走る）。
          // 録音側（RecordingSessionModel）が同じ通知で始めた認識が、捨てるより先に保存へ進まないように
          Task.immediate {
            await self.coordinator.mediaServicesWereReset()
            self.stopObservingIfEnded()
          }
        }
      }
    }
  }

  private func beginObserving() {
    guard pollTask == nil else { return }
    let groupIdentifier = groupIdentifier
    commandObservation = StandbyDarwinSignal.command.observe(groupIdentifier: groupIdentifier) {
      [weak self] in
      Task { @MainActor in await self?.poll() }
    }
    beginObservingAudio()
    // 端末がロックされたら録音を捨てる（閉じても録音を続ける設定でも、ロックの後は続けない, #267）
    lockObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        Task { await self.coordinator.deviceLocked() }
      }
    }
    unlockObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.coordinator.deviceUnlocked() }
    }
    // 通知の欠落に備えて、通知がなくても読み直す。録音の上限・生存の印の途絶・無操作もこれで確かめる
    pollTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: Self.pollInterval)
        guard !Task.isCancelled, let self else { return }
        await poll()
      }
    }
  }

  private func poll() async {
    await coordinator.poll()
    stopObservingIfEnded()
  }

  private func handleInterruption(_ type: AVAudioSession.InterruptionType?) {
    switch type {
    case .began:
      // 録音を捨てるところまで、通知を受けたこの処理の中で進める（メディアサービスのリセットと同じ理由）
      Task.immediate { await coordinator.interruptionBegan() }
    case .ended:
      // shouldResume は見ない（理由は `StandbySessionCoordinator.interruptionEnded()`）
      Task.immediate {
        await coordinator.interruptionEnded()
        stopObservingIfEnded()
      }
    default:
      break
    }
  }

  /// 無操作などで待機が終わっていたら、読み直しと受信をやめる
  private func stopObservingIfEnded() {
    guard !coordinator.isStandingBy, !isStarting else { return }
    pollTask?.cancel()
    pollTask = nil
    commandObservation = nil
    if let interruptionObserver {
      NotificationCenter.default.removeObserver(interruptionObserver)
      self.interruptionObserver = nil
    }
    if let mediaServicesResetObserver {
      NotificationCenter.default.removeObserver(mediaServicesResetObserver)
      self.mediaServicesResetObserver = nil
    }
    if let lockObserver {
      NotificationCenter.default.removeObserver(lockObserver)
      self.lockObserver = nil
    }
    if let unlockObserver {
      NotificationCenter.default.removeObserver(unlockObserver)
      self.unlockObserver = nil
    }
  }
}
