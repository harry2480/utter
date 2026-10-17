import Testing

@testable import UtterCore

struct RecordingInterruptionPolicyTests {
  let policy = RecordingInterruptionPolicy()
  let captured: Duration = .seconds(3)

  @Test(
    "iOS-PERF-03: 着信・バックグラウンド移動・入力機器の喪失・メディアサービスのリセット・熱状態 critical では録音を止めて処理する",
    arguments: [
      (RecordingInterruption.audioInterruptionBegan, RecordingInterruptionCause.audioInterruption),
      (.appDidEnterBackground, .movedToBackground),
      (.audioRouteChanged(.inputDeviceLost), .inputDeviceLost),
      (.mediaServicesReset, .mediaServicesReset),
      (.thermalStateChanged(.critical), .thermalState),
    ]
  )
  func stopsAndProcesses(
    _ interruption: RecordingInterruption, _ cause: RecordingInterruptionCause
  ) {
    #expect(
      policy.decision(for: interruption, capturedAudioDuration: captured)
        == .stopAndProcess(cause))
  }

  @Test(
    "iOS-PERF-03: 一時的な非アクティブ化・割り込みの終了・機器の追加・低電力モード・熱状態の軽い上昇では録音を続ける",
    arguments: [
      RecordingInterruption.appWillResignActive,
      .audioInterruptionEnded,
      .audioRouteChanged(.inputDeviceAdded),
      .audioRouteChanged(.other),
      .lowPowerModeChanged(isEnabled: true),
      .lowPowerModeChanged(isEnabled: false),
      .thermalStateChanged(.nominal),
      .thermalStateChanged(.fair),
      .thermalStateChanged(.serious),
    ]
  )
  func continuesRecording(_ interruption: RecordingInterruption) {
    #expect(
      policy.decision(for: interruption, capturedAudioDuration: captured) == .continueRecording)
  }

  @Test("REC-05: 音声がないときだけ録音を中止し、音声があれば短くても処理する")
  func abortsOnlyWithoutAudio() {
    #expect(
      policy.decision(for: .audioInterruptionBegan, capturedAudioDuration: .zero)
        == .abort(.audioInterruption))
    #expect(
      policy.decision(for: .audioInterruptionBegan, capturedAudioDuration: .milliseconds(1))
        == .stopAndProcess(.audioInterruption))
  }

  @Test("iOS-PERF-03: 処理できる音声の長さの下限は設定で変更できる")
  func usesConfiguredMinimumProcessableAudioDuration() throws {
    let policy = try RecordingInterruptionPolicy(minimumProcessableAudioDuration: .seconds(1))

    #expect(
      policy.decision(for: .appDidEnterBackground, capturedAudioDuration: .seconds(1))
        == .abort(.movedToBackground))
    #expect(
      policy.decision(for: .appDidEnterBackground, capturedAudioDuration: .milliseconds(1001))
        == .stopAndProcess(.movedToBackground))
  }

  @Test("iOS-PERF-03: 録音を止める熱状態は設定で変更できる")
  func usesConfiguredThermalThreshold() throws {
    let policy = try RecordingInterruptionPolicy(thermalStopThreshold: .serious)

    #expect(
      policy.decision(for: .thermalStateChanged(.fair), capturedAudioDuration: captured)
        == .continueRecording)
    #expect(
      policy.decision(for: .thermalStateChanged(.serious), capturedAudioDuration: captured)
        == .stopAndProcess(.thermalState))
    #expect(
      policy.decision(for: .thermalStateChanged(.critical), capturedAudioDuration: captured)
        == .stopAndProcess(.thermalState))
  }

  @Test("iOS-PERF-03: 低電力モードで録音を止めるよう設定できる")
  func stopsOnLowPowerModeWhenConfigured() throws {
    let policy = try RecordingInterruptionPolicy(stopsOnLowPowerMode: true)

    #expect(
      policy.decision(for: .lowPowerModeChanged(isEnabled: true), capturedAudioDuration: captured)
        == .stopAndProcess(.lowPowerMode))
    #expect(
      policy.decision(for: .lowPowerModeChanged(isEnabled: false), capturedAudioDuration: captured)
        == .continueRecording)
  }

  @Test("iOS-PERF-03: 入力機器の喪失で録音を続けるよう設定できる")
  func continuesOnInputDeviceLossWhenConfigured() throws {
    let policy = try RecordingInterruptionPolicy(stopsOnInputDeviceLoss: false)

    #expect(
      policy.decision(
        for: .audioRouteChanged(.inputDeviceLost), capturedAudioDuration: captured)
        == .continueRecording)
  }

  @Test("iOS-PERF-03: 既定値は Phase i0 前の仮定どおり")
  func defaults() throws {
    #expect(policy.thermalStopThreshold == .critical)
    #expect(policy.stopsOnLowPowerMode == false)
    #expect(policy.stopsOnInputDeviceLoss == true)
    #expect(policy.minimumProcessableAudioDuration == .zero)
    #expect(try RecordingInterruptionPolicy(stopsOnLowPowerMode: false) == policy)
  }

  @Test("iOS-PERF-03: 負の音声の長さの下限は拒否する")
  func rejectsNegativeMinimumProcessableAudioDuration() {
    #expect(throws: RecordingInterruptionPolicyError.negativeMinimumProcessableAudioDuration) {
      try RecordingInterruptionPolicy(minimumProcessableAudioDuration: .seconds(-1))
    }
  }

  @Test("iOS-PERF-03: 熱状態は高温ほど大きい")
  func thermalStateIsOrdered() {
    #expect(DeviceThermalState.allCases == DeviceThermalState.allCases.sorted())
    #expect(DeviceThermalState.nominal < .critical)
  }
}
