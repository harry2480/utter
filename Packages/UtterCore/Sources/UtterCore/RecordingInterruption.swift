/// 録音中に起きた割り込み（REC-04, iOS-PERF-03）。
///
/// OS の通知（iOS: オーディオセッションの割り込み・ルート変更・メディアサービスのリセット、
/// アプリのライフサイクル、熱状態、低電力モード。macOS: スリープ、入力機器の切断・既定の入力機器の変更、
/// マイク権限の取り消し）は、アプリ側のアダプター（Apps/iOS・Apps/macOS）でこの値に変換して渡す。
/// UtterCore は OS の型に依存しない。対応表は docs/アーキテクチャ.md の「iOS の録音割り込み」と
/// 「macOS の録音割り込み」を参照。
public enum RecordingInterruption: Hashable, Sendable {
  /// オーディオ割り込みが始まった（電話着信、他アプリの再生、Siri など）。OS はこの時点で録音を止めている
  case audioInterruptionBegan
  /// オーディオ割り込みが終わった。録音は自動で再開しない
  case audioInterruptionEnded
  /// 音声の経路が変わった
  case audioRouteChanged(AudioRouteChange)
  /// メディアサービスがリセットされた。録音エンジンとオーディオセッションは作り直しが必要になる
  case mediaServicesReset
  /// アプリが一時的に非アクティブになった（通知センター・コントロールセンター・着信バナーなど）。
  /// 前面には残っているため、マイクを奪われた場合は `audioInterruptionBegan` が別に届く
  case appWillResignActive
  /// アプリがバックグラウンドへ移った（画面ロック、ホームへの移動、他アプリへの切替）
  case appDidEnterBackground
  /// 熱状態が変わった。値は変化後の状態
  case thermalStateChanged(DeviceThermalState)
  /// 低電力モードが切り替わった
  case lowPowerModeChanged(isEnabled: Bool)
  /// システムがスリープに入る（macOS）。復帰後も録音は自動で再開しない
  case systemWillSleep
  /// システムがスリープから復帰した（macOS）。録音は自動で再開しない
  case systemDidWake
  /// 録音中にマイクの使用許可が取り消された（macOS。REC-04, PERM-02）
  case microphoneAccessRevoked
}

/// 音声の経路の変化。
public enum AudioRouteChange: Hashable, Sendable {
  /// 録音に使っていた入力機器が使えなくなった（ヘッドセットの取り外し、Bluetooth の切断など）
  case inputDeviceLost
  /// 新しい入力機器が使えるようになった
  case inputDeviceAdded
  /// 録音に使っていた入力機器から別の機器に切り替わった（macOS の既定の入力機器の変更）
  case inputDeviceChanged
  /// それ以外（カテゴリやオーバーライドの変更など）
  case other
}

/// 端末の熱状態。値が大きいほど高温。
public enum DeviceThermalState: Int, Comparable, CaseIterable, Sendable {
  case nominal
  case fair
  case serious
  case critical

  public static func < (lhs: DeviceThermalState, rhs: DeviceThermalState) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}

/// 割り込みで録音を止めた原因。HUD や結果画面で理由を示すために使う。
public enum RecordingInterruptionCause: Hashable, Sendable {
  /// オーディオ割り込み（電話着信など）
  case audioInterruption
  /// 入力機器が使えなくなった
  case inputDeviceLost
  /// 入力機器が別の機器に切り替わった（macOS）
  case inputDeviceChanged
  /// メディアサービスのリセット
  case mediaServicesReset
  /// バックグラウンドへの移動（画面ロックを含む）
  case movedToBackground
  /// 熱状態の上昇
  case thermalState
  /// 低電力モード
  case lowPowerMode
  /// システムのスリープ（macOS）
  case systemSleep
  /// マイク権限の取り消し
  case microphoneAccessRevoked
}
