import Testing
import UtterCore

struct MacRecordingInterruptionsTests {
  @Test(
    "REC-04: 録音エンジンの構成変更とスリープは、音声があれば止めて処理し、HUD に macOS の理由を出す",
    arguments: [
      (
        MacRecordingInterruptions.configurationChange, RecordingInterruptionCause.inputDeviceChanged
      ),
      (MacRecordingInterruptions.willSleep, .systemSleep),
    ])
  func stopsAndProcesses(
    interruption: RecordingInterruption, cause: RecordingInterruptionCause
  ) {
    let policy = RecordingInterruptionPolicy()

    #expect(
      policy.decision(for: interruption, capturedAudioDuration: .seconds(1))
        == .stopAndProcess(cause))
    #expect(policy.decision(for: interruption, capturedAudioDuration: .zero) == .abort(cause))
  }

  @Test("REC-04: macOS の値を使い、iOS 用の値（オーディオ割り込み・入力機器の喪失）で表さない")
  func usesMacOSValues() {
    #expect(
      MacRecordingInterruptions.configurationChange == .audioRouteChanged(.inputDeviceChanged))
    #expect(MacRecordingInterruptions.willSleep == .systemWillSleep)
  }
}
