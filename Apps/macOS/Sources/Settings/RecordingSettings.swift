import UtterCore
import UtterPersistence

extension SessionSettings {
  /// 保存された設定の最大録音時間と入力モードから作る（REC-05, 2.2節）。
  ///
  /// 最大録音時間は `AppSettings` が受け付ける範囲（`maxRecordingDurationRange`）に丸めてあり、正の値で検証を通る。
  /// 万一通らなければ既定の構成（暫定5分）を使う
  static func fromSettings(_ settings: AppSettings) -> SessionSettings {
    let configuration =
      (try? SessionConfiguration(maxRecordingDuration: .seconds(settings.maxRecordingDuration)))
      ?? SessionConfiguration()
    return SessionSettings(
      configuration: configuration, inputMode: SessionInputMode(settings.inputMode))
  }
}

extension SessionInputMode {
  /// 保存された入力モードから作る（2.2節）。Realtime Direct は利用者が明示的に選んだときだけ（既定は Instant）
  init(_ mode: InputMode) {
    switch mode {
    case .instant: self = .instant
    case .realtimePreview: self = .realtimePreview
    case .realtimeDirect: self = .realtimeDirect
    }
  }
}

extension GlobalShortcutSetting {
  /// 保存された設定の録音ショートカットと録音の操作方式から作る（REC-01, REC-02）。
  ///
  /// ショートカットが未設定なら `nil`（何も登録しない）。割り当てられるか（修飾キー単独・競合・Esc の予約）は
  /// ここでは判定せず、登録時に `GlobalShortcutController` が `ShortcutValidator` で判定する
  static func fromSettings(_ settings: AppSettings) -> GlobalShortcutSetting? {
    settings.recordingShortcut.map {
      GlobalShortcutSetting(combination: $0, mode: settings.recordingTrigger)
    }
  }
}
