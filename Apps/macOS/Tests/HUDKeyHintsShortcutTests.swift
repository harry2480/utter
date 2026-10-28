import Testing
import UtterCore

/// 録音ショートカットと Esc の捕捉の状態から、HUD に出す停止・キャンセルのキーを決める（REC-01, REC-02, REC-03）。
struct HUDKeyHintsShortcutTests {
  private let optionSpace = KeyCombination(key: .space, modifiers: .option)

  @Test("REC-01, REC-03: 登録済みのショートカットを停止のキーに、捕捉できる Esc をキャンセルのキーに出す")
  func activeShortcutAndEscape() {
    let setting = GlobalShortcutSetting(combination: optionSpace, mode: .toggle)
    let hints = HUDKeyHints(status: .active(setting), escapeStatus: .ready)

    #expect(hints == HUDKeyHints(stopKey: "⌥Space", stopsOnRelease: false, cancelKey: "Esc"))
  }

  @Test("REC-02: Push-to-talk はキーを離すと止まる")
  func pushToTalk() {
    let setting = GlobalShortcutSetting(combination: optionSpace, mode: .pushToTalk)
    let hints = HUDKeyHints(status: .active(setting), escapeStatus: .off)

    #expect(hints == HUDKeyHints(stopKey: "⌥Space", stopsOnRelease: true, cancelKey: nil))
  }

  @Test("REC-01: 使えないショートカット・使えない Esc の捕捉は出さない")
  func unavailableKeysAreOmitted() {
    let setting = GlobalShortcutSetting(combination: optionSpace, mode: .toggle)

    #expect(
      HUDKeyHints(status: .unavailable(setting, .invalid([])), escapeStatus: .off)
        == HUDKeyHints())
    #expect(
      HUDKeyHints(status: .unassigned, escapeStatus: .unavailable(.tapCreationFailed))
        == HUDKeyHints())
    #expect(
      HUDKeyHints(status: .unassigned, escapeStatus: .ready) == HUDKeyHints(cancelKey: "Esc"))
  }
}
