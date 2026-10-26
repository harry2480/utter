import Dispatch
import Foundation
import IOKit.ps
import UtterSpeech
import notify

/// macOS の端末の状態（メモリ圧迫・低電力モード・電源）を監視し、変化を `DeviceResourceSignal` として渡す（6章, AC-11）。
///
/// 待機中の負荷（6章）を増やさないよう、OS の通知だけで動き、タイマーやポーリングを使わない。
/// 通知が来たときに現在の値を読み直して渡す。同じ値が続くかどうかの判定は受け手（`STTWorkerResourceForwarder`）が行う。
///
/// - メモリ圧迫：`DispatchSource.makeMemoryPressureSource`
/// - 低電力モード：`ProcessInfo.isLowPowerModeEnabled` と `NSProcessInfoPowerStateDidChange`
/// - 電源：`IOPSCopyPowerSourcesInfo` / `IOPSGetBatteryWarningLevel` と、notify(3) の
///   `kIOPSNotifyPowerSource`（電源の切り替え）・`kIOPSNotifyLowBattery`（残量警告の変化）。
///   残量の変化ごとに届く `kIOPSNotifyAnyPowerSource` は使わない
@MainActor
final class SystemDeviceResourceMonitor {
  private let queue = DispatchQueue(label: "utter.device-resource-monitor", qos: .utility)
  private var memorySource: (any DispatchSourceMemoryPressure)?
  private var powerStateObserver: (any NSObjectProtocol)?
  private var notifyTokens: [Int32] = []

  /// 監視を始め、始めた時点の状態を返す。以後の変化は `onSignal` に渡す（監視用の直列キューから呼ぶ）。
  ///
  /// 通知を登録してから現在の値を読むため、その間の変化も取りこぼさない（同じ値は受け手で捨てる）。
  /// メモリ圧迫は現在値を問い合わせる公開 API がないため、始めた時点は `normal` とし、次に度合いが変わったときの通知で更新する
  func start(onSignal: @escaping @Sendable (DeviceResourceSignal) -> Void)
    -> DeviceResourceObservation
  {
    stop()
    memorySource = Self.makeMemorySource(queue: queue, onSignal: onSignal)
    powerStateObserver = Self.observeLowPowerMode(queue: queue, onSignal: onSignal)
    notifyTokens = [kIOPSNotifyPowerSource, kIOPSNotifyLowBattery].compactMap {
      Self.registerPowerNotification($0, queue: queue, onSignal: onSignal)
    }
    let power = Self.readPower()
    return DeviceResourceObservation(
      isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
      powerSource: power.source, batteryWarning: power.warning)
  }

  /// 呼び出し側はアプリの終了まで持つが、先に解放されても通知の登録を残さない
  isolated deinit {
    stop()
  }

  /// 監視をやめる
  func stop() {
    memorySource?.cancel()
    memorySource = nil
    if let powerStateObserver {
      NotificationCenter.default.removeObserver(powerStateObserver)
    }
    powerStateObserver = nil
    for token in notifyTokens {
      notify_cancel(token)
    }
    notifyTokens = []
  }

  // 以下はメインアクター外のキューで呼ばれるハンドラーを作るため、nonisolated にしてアクターを引き継がない

  private nonisolated static func makeMemorySource(
    queue: DispatchQueue, onSignal: @escaping @Sendable (DeviceResourceSignal) -> Void
  ) -> any DispatchSourceMemoryPressure {
    let source = DispatchSource.makeMemoryPressureSource(
      eventMask: [.normal, .warning, .critical], queue: queue)
    source.setEventHandler { [weak source] in
      guard let source else { return }
      onSignal(.memoryPressure(MemoryPressure(source.data)))
    }
    source.activate()
    return source
  }

  /// 通知を投げたスレッドではなく監視用のキューで値を読み、ほかの通知と同じ順に並べる
  private nonisolated static func observeLowPowerMode(
    queue: DispatchQueue, onSignal: @escaping @Sendable (DeviceResourceSignal) -> Void
  ) -> any NSObjectProtocol {
    NotificationCenter.default.addObserver(
      forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: nil
    ) { _ in
      queue.async {
        onSignal(.lowPowerMode(isEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled))
      }
    }
  }

  private nonisolated static func registerPowerNotification(
    _ name: String, queue: DispatchQueue,
    onSignal: @escaping @Sendable (DeviceResourceSignal) -> Void
  ) -> Int32? {
    var token: Int32 = 0
    let status = notify_register_dispatch(name, &token, queue) { _ in
      let power = readPower()
      onSignal(.power(source: power.source, batteryWarning: power.warning))
    }
    return status == NOTIFY_STATUS_OK ? token : nil
  }

  private nonisolated static func readPower() -> (
    source: PowerSource, warning: BatteryWarningLevel
  ) {
    let warning: BatteryWarningLevel =
      switch IOPSGetBatteryWarningLevel() {
      case kIOPSLowBatteryWarningEarly: .early
      case kIOPSLowBatteryWarningFinal: .final
      default: .none
      }
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
      let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
    else {
      return (.unknown, warning)
    }
    let source: PowerSource =
      switch type {
      case kIOPMACPowerKey: .externalPower
      // UPS からの給電は限りがあるため、バッテリーとして扱う
      case kIOPMBatteryPowerKey, kIOPMUPSPowerKey: .battery
      default: .unknown
      }
    return (source, warning)
  }
}
