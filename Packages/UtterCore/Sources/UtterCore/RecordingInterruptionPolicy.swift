/// 録音中の割り込みへの対応方針（REC-04, iOS-PERF-03）。
///
/// 割り込みで録音を止めるときも、それまでの音声は破棄せず通常どおり処理する（REC-05）。
/// 処理できる音声がない（`minimumProcessableAudioDuration` 以下）ときだけ録音を中止し、
/// 失敗として表示する。どちらの場合も無言で終わらせない。
///
/// 既定値は Phase i0（実機検証）前の仮定で、検証結果に応じて見直す。
public struct RecordingInterruptionPolicy: Hashable, Sendable {
  /// この熱状態以上になったら録音を止める既定値（暫定: `critical`）
  public static let defaultThermalStopThreshold: DeviceThermalState = .critical
  /// 処理できる音声の長さの下限の既定値（暫定: 0。音声が少しでもあれば処理する）
  public static let defaultMinimumProcessableAudioDuration: Duration = .zero

  /// この熱状態以上になったら録音を止める
  public let thermalStopThreshold: DeviceThermalState
  /// 低電力モードが有効になったら録音を止めるか（暫定: 止めない）
  public let stopsOnLowPowerMode: Bool
  /// 入力機器が使えなくなったら録音を止めるか（暫定: 止める）。
  /// 止めないと、ヘッドセットから内蔵マイクへ切り替わって周囲の音を録り続けるおそれがある。
  /// macOS の既定の入力機器の変更（`inputDeviceChanged`）はこの設定にかかわらず止める。
  /// macOS では続けるには録音エンジンの作り直し（自動再開）が要るため、Apps/macOS は既定値（止める）を使う
  public let stopsOnInputDeviceLoss: Bool
  /// 録音を止めるとき、取得済みの音声がこの長さ以下なら処理せず中止する
  public let minimumProcessableAudioDuration: Duration

  public init() {
    thermalStopThreshold = Self.defaultThermalStopThreshold
    stopsOnLowPowerMode = false
    stopsOnInputDeviceLoss = true
    minimumProcessableAudioDuration = Self.defaultMinimumProcessableAudioDuration
  }

  public init(
    thermalStopThreshold: DeviceThermalState = RecordingInterruptionPolicy
      .defaultThermalStopThreshold,
    stopsOnLowPowerMode: Bool = false,
    stopsOnInputDeviceLoss: Bool = true,
    minimumProcessableAudioDuration: Duration = RecordingInterruptionPolicy
      .defaultMinimumProcessableAudioDuration
  ) throws(RecordingInterruptionPolicyError) {
    guard minimumProcessableAudioDuration >= .zero else {
      throw .negativeMinimumProcessableAudioDuration
    }
    self.thermalStopThreshold = thermalStopThreshold
    self.stopsOnLowPowerMode = stopsOnLowPowerMode
    self.stopsOnInputDeviceLoss = stopsOnInputDeviceLoss
    self.minimumProcessableAudioDuration = minimumProcessableAudioDuration
  }

  /// 録音中に割り込みが起きたときの対応を決める。
  ///
  /// - Parameters:
  ///   - interruption: 起きた割り込み
  ///   - capturedAudioDuration: その時点までに取得できた音声の長さ
  public func decision(
    for interruption: RecordingInterruption,
    capturedAudioDuration: Duration
  ) -> RecordingInterruptionDecision {
    guard let cause = stopCause(for: interruption) else { return .continueRecording }
    guard capturedAudioDuration > minimumProcessableAudioDuration else { return .abort(cause) }
    return .stopAndProcess(cause)
  }

  /// 録音を止める割り込みなら原因を返す。録音を続けてよいなら `nil`。
  private func stopCause(for interruption: RecordingInterruption) -> RecordingInterruptionCause? {
    switch interruption {
    case .audioInterruptionBegan:
      // OS が録音を止めており、着信などの後に自動で再開すると利用者の意図しない録音になる
      return .audioInterruption
    case .audioInterruptionEnded:
      // 割り込みの開始で録音は止めている。終了時に自動で再開しない
      return nil
    case .audioRouteChanged(.inputDeviceLost):
      return stopsOnInputDeviceLoss ? .inputDeviceLost : nil
    case .audioRouteChanged(.inputDeviceChanged):
      // 利用者が選んでいない機器で録り続けない。録音エンジンを作り直して続けると自動再開になるため止める
      return .inputDeviceChanged
    case .audioRouteChanged(.inputDeviceAdded), .audioRouteChanged(.other):
      return nil
    case .mediaServicesReset:
      return .mediaServicesReset
    case .appWillResignActive:
      return nil
    case .appDidEnterBackground:
      // 常時録音のための Background Modes は使わない（iOS-PERF-02, iOS-PERF-03）
      return .movedToBackground
    case .thermalStateChanged(let state):
      return state >= thermalStopThreshold ? .thermalState : nil
    case .lowPowerModeChanged(let isEnabled):
      return isEnabled && stopsOnLowPowerMode ? .lowPowerMode : nil
    case .systemWillSleep:
      // スリープ中は録音できない。スリープ前までの音声を処理する
      return .systemSleep
    case .systemDidWake:
      // スリープに入る時点で録音は止めている。復帰時に自動で再開しない
      return nil
    case .microphoneAccessRevoked:
      // 取り消し後は録音を続けない。取り消し前に取得した音声は通常どおり処理する
      return .microphoneAccessRevoked
    }
  }
}

/// 割り込みへの対応。
public enum RecordingInterruptionDecision: Hashable, Sendable {
  /// 録音を続ける
  case continueRecording
  /// 録音を止め、それまでの音声を通常どおり処理する
  case stopAndProcess(RecordingInterruptionCause)
  /// 処理できる音声がないため録音を中止し、失敗として表示する
  case abort(RecordingInterruptionCause)
}

public enum RecordingInterruptionPolicyError: Error, Hashable, Sendable {
  case negativeMinimumProcessableAudioDuration
}
