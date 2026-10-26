import AVFoundation
import UIKit
import UtteriOSKit

/// 録音に関わる OS の通知を `RecordingSystemSignal` に写し、録音セッションへ渡す（iOS-PERF-03）。
///
/// 対応表は docs/アーキテクチャ.md の「iOS の録音割り込み」。録音を止めるかの判断はしない（`RecordingInterruptionPolicy`）。
/// 録音中でなければ、渡した通知はセッション側で無視される。アプリの起動部が保持し、アプリと同じ間だけ生きる。
@MainActor
final class RecordingSignalObserver {
  private var observers: [any NSObjectProtocol] = []

  init(model: RecordingSessionModel) {
    observe(AVAudioSession.interruptionNotification, model: model) { notification in
      guard
        let rawValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
        let type = AVAudioSession.InterruptionType(rawValue: rawValue)
      else { return nil }
      return .audioSessionInterruption(began: type == .began)
    }
    observe(AVAudioSession.routeChangeNotification, model: model) { notification in
      guard
        let rawValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
        let reason = AVAudioSession.RouteChangeReason(rawValue: rawValue)
      else { return .audioRouteChange(.other) }
      return switch reason {
      case .newDeviceAvailable: .audioRouteChange(.newDeviceAvailable)
      // 使える入力がなくなった場合も、入力機器の喪失として扱う
      case .oldDeviceUnavailable, .noSuitableRouteForCategory:
        .audioRouteChange(.oldDeviceUnavailable)
      default: .audioRouteChange(.other)
      }
    }
    observe(AVAudioSession.mediaServicesWereResetNotification, model: model) { _ in
      .mediaServicesReset
    }
    observe(UIApplication.willResignActiveNotification, model: model) { _ in .appWillResignActive }
    observe(UIApplication.didEnterBackgroundNotification, model: model) { _ in
      .appDidEnterBackground
    }
    observe(ProcessInfo.thermalStateDidChangeNotification, model: model) { _ in
      .thermalStateChanged(ProcessInfo.processInfo.thermalState)
    }
    observe(.NSProcessInfoPowerStateDidChange, model: model) { _ in
      .lowPowerModeChanged(isEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }
  }

  /// 通知はメインキューで受け、そのままセッションへ渡す（割り込みの順序を保つ）
  private func observe(
    _ name: Notification.Name,
    model: RecordingSessionModel,
    signal: @escaping @Sendable (Notification) -> RecordingSystemSignal?
  ) {
    observers.append(
      NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
        [weak model] notification in
        guard let signal = signal(notification) else { return }
        MainActor.assumeIsolated { model?.handle(signal) }
      })
  }
}
