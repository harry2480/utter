import Foundation
import Testing
import UtterCore

@testable import UtterPersistence

/// テストごとに専用の suite を使い、終わったら消す
private final class TestDefaults {
  let suiteName: String
  let defaults: UserDefaults

  init(_ name: String) throws {
    suiteName = "utter.tests.AppSettingsStore.\(name)"
    defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
  }

  deinit {
    defaults.removePersistentDomain(forName: suiteName)
  }
}

struct AppSettingsStoreTests {
  @Test("2.3節, AC-06: 未保存なら既定値（同意はすべて未同意）を返す")
  func loadsDefaultsWhenNothingStored() throws {
    let suite = try TestDefaults("empty")
    let settings = AppSettingsStore(defaults: suite.defaults).load()

    #expect(settings == AppSettings())
    #expect(!settings.consentState.allows(.textRefinement(.claude)))
  }

  @Test("2.3節, 5章, 7章: 保存した設定を注入した UserDefaults から復元できる")
  func savesAndLoads() throws {
    let suite = try TestDefaults("roundTrip")
    var consentState = ConsentState()
    consentState.grant(.transmission(.textRefinement(.claude)))
    let settings = AppSettings(
      maxRecordingDuration: 120,
      recordingTrigger: .pushToTalk,
      recordingShortcut: KeyCombination(modifierOnly: [.function]),
      inputMode: .realtimePreview,
      refinementMode: .raw,
      refinementEngine: .cloudAI,
      appStyleOverrides: ["com.apple.terminal": .command],
      siteIdentificationAllowed: true,
      siteStyleOverrides: ["example.com": .technical],
      refinementModel: "model-a",
      monthlyBudget: MonthlyBudgetSetting(limitAmount: 5, currencyCode: "USD"),
      consentState: consentState,
      historyEnabled: true,
      modelRetentionMode: .powerSaving,
      excludedApps: ["com.example.secret"])

    try AppSettingsStore(defaults: suite.defaults).save(settings)
    let loaded = AppSettingsStore(defaults: suite.defaults).load()

    #expect(loaded == settings)
    #expect(loaded.consentState.allows(.textRefinement(.claude)))
  }

  @Test("2.3節, AC-06: 版 1 で保存した設定を読み、保存し直すと版 2 になって値を保つ")
  func version1DataIsMigratedOnSave() throws {
    let suite = try TestDefaults("migration")
    var consentState = ConsentState()
    consentState.grant(.transmission(.textRefinement(.claude)))
    let consent = String(decoding: try JSONEncoder().encode(consentState), as: UTF8.self)
    let version1 =
      #"{"version": 1, "maxRecordingDuration": 90, "refinementModel": "model-a", "#
      + #""historyEnabled": true, "consentState": \#(consent)}"#
    suite.defaults.set(Data(version1.utf8), forKey: AppSettingsStore.key)
    let store = AppSettingsStore(defaults: suite.defaults)

    var loaded = store.load()
    loaded.recordingTrigger = .pushToTalk
    try store.save(loaded)

    let data = try #require(suite.defaults.data(forKey: AppSettingsStore.key))
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["version"] as? Int == 2)
    let reloaded = store.load()
    #expect(reloaded.maxRecordingDuration == 90)
    #expect(reloaded.refinementModel == "model-a")
    #expect(reloaded.historyEnabled)
    #expect(reloaded.consentState.allows(.textRefinement(.claude)))
    #expect(reloaded.recordingTrigger == .pushToTalk)
    #expect(reloaded.inputMode == .instant)
  }

  @Test("2.3節: 別の suite には保存が漏れない")
  func suitesAreIsolated() throws {
    let first = try TestDefaults("isolatedA")
    let second = try TestDefaults("isolatedB")

    try AppSettingsStore(defaults: first.defaults).save(AppSettings(historyEnabled: true))

    #expect(AppSettingsStore(defaults: second.defaults).load() == AppSettings())
  }

  @Test(
    "2.3節, AC-06: 保存値が壊れていれば既定値で復元し、同意は未同意に倒す",
    arguments: [
      Data("not json".utf8),
      Data(),
      Data(#"{"version": 99, "consentState": {}}"#.utf8),
    ])
  func corruptedDataRevertsToDefaults(data: Data) throws {
    let suite = try TestDefaults("corrupted.\(data.count)")
    suite.defaults.set(data, forKey: AppSettingsStore.key)

    let settings = AppSettingsStore(defaults: suite.defaults).load()

    #expect(settings == AppSettings())
    #expect(!settings.consentState.allows(.textRefinement(.claude)))
  }

  @Test("2.3節: Data でない値が保存されていても既定値で復元する")
  func wrongStoredTypeRevertsToDefaults() throws {
    let suite = try TestDefaults("wrongType")
    suite.defaults.set("settings", forKey: AppSettingsStore.key)

    #expect(AppSettingsStore(defaults: suite.defaults).load() == AppSettings())
  }

  @Test("7章, AC-06: reset で保存値を消し、既定値に戻す")
  func resetRemovesStoredSettings() throws {
    let suite = try TestDefaults("reset")
    let store = AppSettingsStore(defaults: suite.defaults)
    var consentState = ConsentState()
    consentState.grant(.transmission(.speechRecognition))
    try store.save(AppSettings(consentState: consentState, historyEnabled: true))

    store.reset()

    #expect(suite.defaults.object(forKey: AppSettingsStore.key) == nil)
    #expect(store.load() == AppSettings())
  }
}
