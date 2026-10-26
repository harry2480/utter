import Testing
import UtterPersistence
import UtterSpeech

@Suite("設定の保持モードから STT Worker へ送る方針を作る（6章）")
struct ModelRetentionSettingsTests {
  @Test("保持モードをそのまま対応させる", arguments: ModelRetentionModeSetting.allCases)
  func mapsEachMode(setting: ModelRetentionModeSetting) {
    let mode = ModelRetentionMode(setting)
    switch setting {
    case .powerSaving: #expect(mode == .powerSaving)
    case .balanced: #expect(mode == .balanced)
    case .performance: #expect(mode == .performance)
    }
  }

  @Test("既定の設定はバランスモードで、保持時間は既定値")
  func defaultSettingsAreBalanced() throws {
    let policy = try #require(ModelRetentionPolicy.fromSettings(AppSettings()))
    #expect(policy.effectiveMode == .balanced)
    #expect(policy.balancedRetention == ModelRetentionPolicy.defaultBalancedRetention)
  }

  @Test("高速モードは許可があるときだけ高速モードとして扱う")
  func performanceNeedsPermission() throws {
    var settings = AppSettings()
    settings.modelRetentionMode = .performance
    settings.performanceRetentionAllowed = false
    let withoutPermission = try #require(ModelRetentionPolicy.fromSettings(settings))
    #expect(withoutPermission.effectiveMode == .balanced)

    settings.performanceRetentionAllowed = true
    let withPermission = try #require(ModelRetentionPolicy.fromSettings(settings))
    #expect(withPermission.effectiveMode == .performance)
  }
}
