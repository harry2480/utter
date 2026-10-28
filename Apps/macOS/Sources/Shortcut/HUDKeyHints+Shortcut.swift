import UtterCore

extension HUDKeyHints {
  /// 録音ショートカットと Esc の捕捉の状態から、HUD に出す停止・キャンセルのキーを決める（REC-01, REC-02）。
  ///
  /// 登録できていないショートカットは停止のキーに出さない。キャンセルは Esc を捕捉できるとき
  /// （#51 の判定待ちで既定は無効）だけ出す
  init(status: GlobalShortcutStatus, escapeStatus: EscapeCaptureStatus) {
    let cancelKey: String? = escapeStatus == .ready ? "Esc" : nil
    switch status {
    case .active(let setting):
      self.init(
        stopKey: ShortcutNotation.display(setting), stopsOnRelease: setting.mode == .pushToTalk,
        cancelKey: cancelKey)
    case .unassigned, .unavailable:
      self.init(cancelKey: cancelKey)
    }
  }
}
