import Foundation
import UtterCore

/// 録音中に OS から届く通知の内容（iOS-PERF-03）。
///
/// AVAudioSession の型は macOS で使えずテストできないため、Apps/iOS のアダプターが通知をこの値に写し、
/// `recordingInterruption` で UtterCore の `RecordingInterruption` に変換する。
/// 対応表は docs/アーキテクチャ.md の「iOS の録音割り込み」。
public enum RecordingSystemSignal: Hashable, Sendable {
  /// `AVAudioSession.interruptionNotification`。`began` は `InterruptionType.began` なら `true`
  case audioSessionInterruption(began: Bool)
  /// `AVAudioSession.routeChangeNotification`
  case audioRouteChange(AudioSessionRouteChangeReason)
  /// `AVAudioSession.mediaServicesWereResetNotification`
  case mediaServicesReset
  /// `UIApplication.willResignActiveNotification`
  case appWillResignActive
  /// `UIApplication.didEnterBackgroundNotification`（画面ロックを含む）
  case appDidEnterBackground
  /// `ProcessInfo.thermalStateDidChangeNotification`。値は変化後の `ProcessInfo.thermalState`
  case thermalStateChanged(ProcessInfo.ThermalState)
  /// `NSProcessInfoPowerStateDidChange`。値は変化後の `ProcessInfo.isLowPowerModeEnabled`
  case lowPowerModeChanged(isEnabled: Bool)

  /// UtterCore の割り込みに変換する。
  public var recordingInterruption: RecordingInterruption {
    switch self {
    case .audioSessionInterruption(let began):
      began ? .audioInterruptionBegan : .audioInterruptionEnded
    case .audioRouteChange(.oldDeviceUnavailable):
      .audioRouteChanged(.inputDeviceLost)
    case .audioRouteChange(.newDeviceAvailable):
      .audioRouteChanged(.inputDeviceAdded)
    case .audioRouteChange(.other):
      .audioRouteChanged(.other)
    case .mediaServicesReset:
      .mediaServicesReset
    case .appWillResignActive:
      .appWillResignActive
    case .appDidEnterBackground:
      .appDidEnterBackground
    case .thermalStateChanged(let state):
      .thermalStateChanged(Self.deviceThermalState(state))
    case .lowPowerModeChanged(let isEnabled):
      .lowPowerModeChanged(isEnabled: isEnabled)
    }
  }

  /// 未知の熱状態（OS の将来の追加）は、録音を止める側の `critical` として扱う（安全側）
  static func deviceThermalState(_ state: ProcessInfo.ThermalState) -> DeviceThermalState {
    switch state {
    case .nominal: .nominal
    case .fair: .fair
    case .serious: .serious
    case .critical: .critical
    @unknown default: .critical
    }
  }
}

/// `AVAudioSession.RouteChangeReason` のうち、録音の継続を左右するもの。
public enum AudioSessionRouteChangeReason: Hashable, Sendable {
  /// `.newDeviceAvailable`（ヘッドセットの接続など）
  case newDeviceAvailable
  /// `.oldDeviceUnavailable`（ヘッドセットの取り外し、Bluetooth の切断など）
  case oldDeviceUnavailable
  /// それ以外（カテゴリやオーバーライドの変更など）
  case other
}
