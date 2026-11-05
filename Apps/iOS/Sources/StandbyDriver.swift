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
  @ObservationIgnored private var pollTask: Task<Void, Never>?
  @ObservationIgnored private var commandObservation: StandbyDarwinObservation?
  @ObservationIgnored private var interruptionObserver: (any NSObjectProtocol)?

  /// 状態を読み直す間隔。本体アプリの更新が途絶えた判定（8秒）より十分短くする
  private static let pollInterval: Duration = .seconds(1)

  init(
    coordinator: StandbySessionCoordinator, audio: StandbyAudioSessionAdapter,
    preferences: StandbyPreferences, groupIdentifier: String
  ) {
    self.coordinator = coordinator
    self.audio = audio
    self.preferences = preferences
    self.groupIdentifier = groupIdentifier
  }

  var isStandingBy: Bool { coordinator.isStandingBy }

  /// 利用者が待機を始める
  func start() async {
    guard !coordinator.isStandingBy else { return }
    coordinator.updateConfiguration(preferences.sessionConfiguration)
    startFailed = false
    guard await coordinator.startStandby() else {
      startFailed = true
      return
    }
    // 始める途中に終える操作を受けていたら、すでに終わっている
    guard coordinator.isStandingBy else { return }
    beginObserving()
  }

  /// 利用者が待機を終える
  func end() async {
    await coordinator.endStandby()
    stopObservingIfEnded()
  }

  private func beginObserving() {
    guard pollTask == nil else { return }
    let groupIdentifier = groupIdentifier
    commandObservation = StandbyDarwinSignal.command.observe(groupIdentifier: groupIdentifier) {
      [weak self] in
      Task { @MainActor in await self?.poll() }
    }
    interruptionObserver = NotificationCenter.default.addObserver(
      forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
    ) { [weak self] notification in
      let rawValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
      let type = rawValue.flatMap(AVAudioSession.InterruptionType.init(rawValue:))
      MainActor.assumeIsolated { self?.handleInterruption(type) }
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
      Task { await coordinator.interruptionBegan() }
    case .ended:
      audio.resumeAfterInterruption()
    default:
      break
    }
  }

  /// 無操作などで待機が終わっていたら、読み直しと受信をやめる
  private func stopObservingIfEnded() {
    guard !coordinator.isStandingBy else { return }
    pollTask?.cancel()
    pollTask = nil
    commandObservation = nil
    if let interruptionObserver {
      NotificationCenter.default.removeObserver(interruptionObserver)
      self.interruptionObserver = nil
    }
  }
}
