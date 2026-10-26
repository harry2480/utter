import Dispatch
import Testing

@testable import UtterSpeech

struct DeviceResourceObservationTests {
  @Test("AC-11: メモリ圧迫の通知を判定用の値に変換し、複数の度合いは重い方にする")
  func convertsMemoryPressureEvent() {
    #expect(MemoryPressure(DispatchSource.MemoryPressureEvent.normal) == .normal)
    #expect(MemoryPressure(DispatchSource.MemoryPressureEvent.warning) == .warning)
    #expect(MemoryPressure(DispatchSource.MemoryPressureEvent.critical) == .critical)
    #expect(MemoryPressure([DispatchSource.MemoryPressureEvent.warning, .critical]) == .critical)
    #expect(MemoryPressure(DispatchSource.MemoryPressureEvent()) == .normal)
  }

  @Test("AC-11: メモリ圧迫の変化を端末の状態に反映する")
  func appliesMemoryPressure() {
    var observation = DeviceResourceObservation()

    observation.apply(.memoryPressure(.warning))
    #expect(observation.deviceState == DeviceResourceState(memoryPressure: .warning))

    observation.apply(.memoryPressure(.critical))
    #expect(observation.deviceState == DeviceResourceState(memoryPressure: .critical))

    observation.apply(.memoryPressure(.normal))
    #expect(observation.deviceState == DeviceResourceState())
  }

  @Test("6章: 低電力モードは電源によらず低バッテリーとして扱う")
  func lowPowerModeIsBatteryLow() {
    var observation = DeviceResourceObservation(powerSource: .externalPower)

    observation.apply(.lowPowerMode(isEnabled: true))
    #expect(observation.deviceState == DeviceResourceState(isBatteryLow: true))

    observation.apply(.lowPowerMode(isEnabled: false))
    #expect(observation.deviceState == DeviceResourceState())
  }

  @Test(
    "6章: バッテリー駆動で OS の残量警告が出ていれば低バッテリーとして扱う",
    arguments: [
      (PowerSource.battery, BatteryWarningLevel.none, false),
      (.battery, .early, true),
      (.battery, .final, true),
      // 外部電源では警告が残っていても低バッテリーにしない
      (.externalPower, .early, false),
      (.externalPower, .none, false),
      // 電源の種類が取れないときは警告に従う（安全側）
      (.unknown, .early, true),
      (.unknown, .none, false),
    ])
  func batteryWarningOnLimitedPower(
    _ source: PowerSource, _ warning: BatteryWarningLevel, _ isBatteryLow: Bool
  ) {
    var observation = DeviceResourceObservation()

    observation.apply(.power(source: source, batteryWarning: warning))

    #expect(observation.deviceState == DeviceResourceState(isBatteryLow: isBatteryLow))
  }

  @Test("6章, AC-11: 種類の違う変化は互いの値を変えない")
  func signalsAreIndependent() {
    var observation = DeviceResourceObservation()

    observation.apply(.memoryPressure(.warning))
    observation.apply(.power(source: .battery, batteryWarning: .early))
    observation.apply(.lowPowerMode(isEnabled: false))

    #expect(
      observation
        == DeviceResourceObservation(
          memoryPressure: .warning, powerSource: .battery, batteryWarning: .early))
    #expect(
      observation.deviceState == DeviceResourceState(memoryPressure: .warning, isBatteryLow: true))
  }
}
