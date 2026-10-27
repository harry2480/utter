import Testing
import UtterCore
import UtterPersistence

@Suite("設定の録音の項目から、セッションとショートカットに使う値を作る（REC-01, REC-02, REC-05, 2.2節）")
struct RecordingSettingsTests {
  @Test("REC-05, 2.2節: 既定の設定は最大録音時間が既定値（暫定5分）で、入力モードは Instant")
  func defaultSessionSettings() {
    let settings = SessionSettings.fromSettings(AppSettings())
    #expect(settings.configuration == SessionConfiguration())
    #expect(!settings.showsRealtimePreview)
  }

  @Test("REC-05: 最大録音時間を秒から換算する（端数も含める）")
  func convertsMaxRecordingDuration() throws {
    var settings = AppSettings()
    settings.maxRecordingDuration = 90.5
    let configuration = SessionSettings.fromSettings(settings).configuration
    #expect(configuration.maxRecordingDuration == .milliseconds(90_500))
  }

  @Test("2.2節: 入力モードが Realtime Preview のときだけ認識テキストを HUD に出す", arguments: InputMode.allCases)
  func mapsInputMode(mode: InputMode) {
    var settings = AppSettings()
    settings.inputMode = mode
    let shows = SessionSettings.fromSettings(settings).showsRealtimePreview
    switch mode {
    case .instant: #expect(!shows)
    case .realtimePreview: #expect(shows)
    }
  }

  @Test("REC-01: 録音ショートカットが未設定なら割当なし")
  func unsetShortcutIsUnassigned() {
    var settings = AppSettings()
    settings.recordingTrigger = .pushToTalk
    #expect(GlobalShortcutSetting.fromSettings(settings) == nil)
  }

  @Test("REC-02: 録音ショートカットと録音の操作方式をそのまま使う", arguments: ShortcutTriggerMode.allCases)
  func mapsShortcutAndTrigger(mode: ShortcutTriggerMode) throws {
    let combination = try #require(ShortcutNotation.parse("ctrl+option+k"))
    var settings = AppSettings()
    settings.recordingShortcut = combination
    settings.recordingTrigger = mode
    #expect(
      GlobalShortcutSetting.fromSettings(settings)
        == GlobalShortcutSetting(combination: combination, mode: mode))
  }
}
