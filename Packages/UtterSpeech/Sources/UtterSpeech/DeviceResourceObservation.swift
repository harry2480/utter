import Dispatch

/// 端末の電源の種類（6章）。OS 固有の値はアプリ側でこの値に変換する
public enum PowerSource: Hashable, Sendable {
  /// 取得できない
  case unknown
  /// AC アダプターなど、外部電源から給電している
  case externalPower
  /// 内蔵バッテリーなど、限りのある電源から給電している（UPS のバッテリーを含む）
  case battery
}

/// OS が判定したバッテリー残量の警告（6章）。残量の閾値はアプリで持たず、OS の判定に従う
public enum BatteryWarningLevel: Hashable, Sendable {
  case none
  /// OS がバッテリー残量の警告を出し始めた段階
  case early
  /// OS が最後の警告を出した段階
  case final
}

/// 端末の状態の監視で届く変化（6章, AC-11）。監視する OS の通知ごとに1種類
public enum DeviceResourceSignal: Hashable, Sendable {
  case memoryPressure(MemoryPressure)
  case lowPowerMode(isEnabled: Bool)
  case power(source: PowerSource, batteryWarning: BatteryWarningLevel)
}

/// 監視で得た端末の状態の現在値（6章, AC-11）。`DeviceResourceSignal` を適用して更新し、`deviceState` で判定用の値に変換する
public struct DeviceResourceObservation: Hashable, Sendable {
  public var memoryPressure: MemoryPressure
  public var isLowPowerModeEnabled: Bool
  public var powerSource: PowerSource
  public var batteryWarning: BatteryWarningLevel

  public init(
    memoryPressure: MemoryPressure = .normal,
    isLowPowerModeEnabled: Bool = false,
    powerSource: PowerSource = .unknown,
    batteryWarning: BatteryWarningLevel = .none
  ) {
    self.memoryPressure = memoryPressure
    self.isLowPowerModeEnabled = isLowPowerModeEnabled
    self.powerSource = powerSource
    self.batteryWarning = batteryWarning
  }

  public mutating func apply(_ signal: DeviceResourceSignal) {
    switch signal {
    case .memoryPressure(let pressure):
      memoryPressure = pressure
    case .lowPowerMode(let isEnabled):
      isLowPowerModeEnabled = isEnabled
    case .power(let source, let warning):
      powerSource = source
      batteryWarning = warning
    }
  }

  /// `ModelRetentionPolicy` の判定に使う値。
  ///
  /// 低バッテリーは「低電力モード」か「外部電源でなく、OS がバッテリー残量の警告を出している」とする。
  /// 残量の閾値（%）は持たず、OS の警告に従う。電源の種類が取れないときに警告が出ていれば、安全側（解放）に倒して低バッテリーとする
  public var deviceState: DeviceResourceState {
    let isBatteryWarning = powerSource != .externalPower && batteryWarning != .none
    return DeviceResourceState(
      memoryPressure: memoryPressure,
      isBatteryLow: isLowPowerModeEnabled || isBatteryWarning)
  }
}

extension MemoryPressure {
  /// `DispatchSource.makeMemoryPressureSource` の通知を変換する。複数の度合いが含まれるときは重い方にする
  public init(_ event: DispatchSource.MemoryPressureEvent) {
    if event.contains(.critical) {
      self = .critical
    } else if event.contains(.warning) {
      self = .warning
    } else {
      self = .normal
    }
  }
}
