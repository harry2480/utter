import Foundation
import Testing
import UtterCore

@testable import UtteriOSKit

struct RecordingSystemSignalTests {
  @Test(
    "iOS-PERF-03: OS の通知を UtterCore の割り込みに変換する",
    arguments: [
      (RecordingSystemSignal.audioSessionInterruption(began: true), .audioInterruptionBegan),
      (.audioSessionInterruption(began: false), .audioInterruptionEnded),
      (.audioRouteChange(.oldDeviceUnavailable), .audioRouteChanged(.inputDeviceLost)),
      (.audioRouteChange(.newDeviceAvailable), .audioRouteChanged(.inputDeviceAdded)),
      (.audioRouteChange(.other), .audioRouteChanged(.other)),
      (.mediaServicesReset, .mediaServicesReset),
      (.appWillResignActive, .appWillResignActive),
      (.appDidEnterBackground, .appDidEnterBackground),
      (.lowPowerModeChanged(isEnabled: true), .lowPowerModeChanged(isEnabled: true)),
      (.lowPowerModeChanged(isEnabled: false), .lowPowerModeChanged(isEnabled: false)),
    ] as [(RecordingSystemSignal, RecordingInterruption)])
  func translates(_ signal: RecordingSystemSignal, _ expected: RecordingInterruption) {
    #expect(signal.recordingInterruption == expected)
  }

  @Test(
    "iOS-PERF-03: ProcessInfo の熱状態を同じ段階に変換する",
    arguments: [
      (ProcessInfo.ThermalState.nominal, DeviceThermalState.nominal),
      (.fair, .fair),
      (.serious, .serious),
      (.critical, .critical),
    ])
  func translatesThermalState(_ state: ProcessInfo.ThermalState, _ expected: DeviceThermalState) {
    #expect(
      RecordingSystemSignal.thermalStateChanged(state).recordingInterruption
        == .thermalStateChanged(expected))
  }
}
