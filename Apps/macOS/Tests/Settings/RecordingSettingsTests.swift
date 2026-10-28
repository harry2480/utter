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
    #expect(settings.inputMode == .instant)
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
    let session = SessionSettings.fromSettings(settings)
    switch mode {
    case .instant:
      #expect(session.inputMode == .instant)
      #expect(!session.showsRealtimePreview)
    case .realtimePreview:
      #expect(session.inputMode == .realtimePreview)
      #expect(session.showsRealtimePreview)
    case .realtimeDirect:
      // Realtime Direct は認識テキストを HUD に出さず、入力欄へ逐次書き込む（AC-15）
      #expect(session.inputMode == .realtimeDirect)
      #expect(!session.showsRealtimePreview)
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

  @Test("REC-01, REC-06: 処理中の押下の動作と Esc でのキャンセルを設定から読む")
  func mapsPressWhileProcessingAndEscape() throws {
    let combination = try #require(ShortcutNotation.parse("ctrl+option+k"))
    var settings = AppSettings()
    settings.recordingShortcut = combination
    settings.recordingPressWhileProcessing = .confirmCancel
    settings.escapeCancelEnabled = false

    let setting = try #require(GlobalShortcutSetting.fromSettings(settings))
    #expect(setting.pressWhileProcessing == .confirmCancel)
    #expect(!setting.cancelsWithEscape)

    // 既定は何もしない・Esc でキャンセルする（Esc の捕捉そのものは capability が有効なときだけ）
    let defaults = try #require(
      GlobalShortcutSetting.fromSettings(AppSettings(recordingShortcut: combination)))
    #expect(defaults.pressWhileProcessing == .ignore)
    #expect(defaults.cancelsWithEscape)
  }
}
