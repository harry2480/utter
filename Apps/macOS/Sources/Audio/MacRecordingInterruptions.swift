import UtterCore

/// macOS の録音で受ける OS の通知を表す `RecordingInterruption` の値（REC-04）。
///
/// `AVAudioEngineRecorder` が通知を受けたときに渡す値をここにまとめ、テストで既定の方針での扱いを確かめる。
/// 対応表は docs/アーキテクチャ.md の「macOS の録音割り込み」「macOS の録音（AVAudioEngine）」を参照。
enum MacRecordingInterruptions {
  /// `AVAudioEngineConfigurationChange`。エンジンは止まっており、録音に使っていた入力機器では続けられない。
  /// 既定の入力機器の変更と機器の切断を通知だけでは区別できないため、既定の入力機器の変更に寄せる
  static let configurationChange = RecordingInterruption.audioRouteChanged(.inputDeviceChanged)

  /// `NSWorkspace.willSleepNotification`。復帰後も自動で再開しない
  static let willSleep = RecordingInterruption.systemWillSleep
}
