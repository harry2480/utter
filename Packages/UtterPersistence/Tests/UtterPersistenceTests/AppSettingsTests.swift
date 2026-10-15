import Foundation
import Testing
import UtterCore

@testable import UtterPersistence

struct AppSettingsTests {
  @Test("AC-06: 既定値ですべて未同意で初期化される")
  func defaultConsentIsNotGranted() {
    let settings = AppSettings()
    let consentState = settings.consentState

    #expect(!consentState.allows(.textRefinement(.claude)))
    #expect(!consentState.allows(.textRefinement(.chatGPT)))
    #expect(!consentState.allows(.speechRecognition))
  }

  @Test("2.1節: 最大録音時間は設定で変えられる")
  func recordingDurationIsConfigurable() {
    var settings = AppSettings(maxRecordingDuration: 600)
    #expect(settings.maxRecordingDuration == 600)

    settings.maxRecordingDuration = 300
    #expect(settings.maxRecordingDuration == 300)
  }

  @Test("AI-03: 整形モード（LocalBasic / CloudAI）は設定で変えられる")
  func refinementModeIsConfigurable() {
    var settings = AppSettings(refinementMode: .localBasic)
    #expect(settings.refinementMode == .localBasic)

    settings.refinementMode = .cloudAI
    #expect(settings.refinementMode == .cloudAI)
  }

  @Test("CTX-02: アプリ別スタイル上書きは設定で変えられる")
  func appStyleOverridesAreConfigurable() {
    let targetID = InsertionTargetID(rawValue: "com.apple.Terminal")
    var settings = AppSettings()

    settings.appStyleOverrides[targetID] = .command
    #expect(settings.appStyleOverrides[targetID] == .command)
  }

  @Test("AI-07: 整形用モデル名は設定で変えられる")
  func refinementModelIsConfigurable() {
    var settings = AppSettings()
    settings.refinementModel = "gpt-4"
    #expect(settings.refinementModel == "gpt-4")
  }

  @Test("AI-05: 単価表は設定で変えられる")
  func priceTableIsConfigurable() {
    var settings = AppSettings()
    settings.pricePerMillionTokens = ["claude-3-sonnet": 3.0, "gpt-4": 30.0]

    #expect(settings.pricePerMillionTokens["claude-3-sonnet"] == 3.0)
    #expect(settings.pricePerMillionTokens["gpt-4"] == 30.0)
  }

  @Test("AI-05: 単価表の更新日は記録できる")
  func priceTableUpdateDateIsRecorded() {
    let now = Date()
    var settings = AppSettings()
    settings.priceTableUpdatedAt = now

    #expect(settings.priceTableUpdatedAt == now)
  }

  @Test("月次予算は設定で変えられる")
  func monthlyBudgetIsConfigurable() {
    var settings = AppSettings(monthlyBudget: 20.0)
    #expect(settings.monthlyBudget == 20.0)

    settings.monthlyBudget = 50.0
    #expect(settings.monthlyBudget == 50.0)
  }

  @Test("AC-06: 同意状態は設定で変えられる")
  func consentStateIsConfigurable() {
    var settings = AppSettings()
    var consentState = ConsentState()
    consentState.grant(.transmission(.textRefinement(.claude)))

    settings.consentState = consentState
    #expect(settings.consentState.allows(.textRefinement(.claude)))
  }

  @Test("7章: 履歴は既定で無効")
  func historyDisabledByDefault() {
    let settings = AppSettings()
    #expect(settings.historyEnabled == false)
  }

  @Test("7章: 履歴の有効・無効は設定で変えられる")
  func historyIsConfigurable() {
    let settings = AppSettings(historyEnabled: true)
    #expect(settings.historyEnabled == true)
  }

  @Test("2.3節: 不足した値は既定値で復元される")
  func missingValuesRevertToDefaults() throws {
    let json = """
      {
        "version": 1
      }
      """.data(using: .utf8)!

    let decoder = JSONDecoder()
    let settings = try decoder.decode(AppSettings.self, from: json)

    // 壊れた値は既定値で復元
    #expect(settings.maxRecordingDuration == 300)
    #expect(settings.refinementMode == .localBasic)
    #expect(settings.refinementModel == "claude-3-5-sonnet-20241022")
    #expect(settings.monthlyBudget == 10.0)
  }

  @Test("2.3節: バージョンフィールドも不足時は既定値で復元される")
  func missingVersionRevertToDefault() throws {
    let json = """
      {
      }
      """.data(using: .utf8)!

    let decoder = JSONDecoder()
    let settings = try decoder.decode(AppSettings.self, from: json)

    // バージョンが不足していても既定値（1）で復元
    #expect(settings.version == 1)
    #expect(settings.maxRecordingDuration == 300)
  }

  @Test("未知の版は既定値で復元される")
  func unknownVersionRevertToDefaults() throws {
    let json = """
      {
        "version": 999,
        "maxRecordingDuration": 500,
        "refinementMode": "cloudAI"
      }
      """.data(using: .utf8)!

    let decoder = JSONDecoder()
    let settings = try decoder.decode(AppSettings.self, from: json)

    // 未知の版は既定値で復元
    #expect(settings.maxRecordingDuration == 300)
    #expect(settings.refinementMode == .localBasic)
  }

  @Test("AC-06: 壊れた同意状態は既定の未同意で復元される")
  func corruptedConsentStateRevertToDefault() throws {
    let json = """
      {
        "version": 1,
        "consentState": null
      }
      """.data(using: .utf8)!

    let decoder = JSONDecoder()
    let settings = try decoder.decode(AppSettings.self, from: json)

    #expect(!settings.consentState.allows(.textRefinement(.claude)))
  }

  @Test("2.3節: 設定は Codable でシリアライズできる")
  func settingsCanBeCodableEncoded() throws {
    var settings = AppSettings()
    settings.refinementMode = .cloudAI
    settings.monthlyBudget = 25.0

    let encoder = JSONEncoder()
    let encoded = try encoder.encode(settings)
    let decoder = JSONDecoder()
    let decoded = try decoder.decode(AppSettings.self, from: encoded)

    #expect(decoded.refinementMode == .cloudAI)
    #expect(decoded.monthlyBudget == 25.0)
  }

  @Test("CTX-02: アプリ別スタイル上書きは Codable でシリアライズできる")
  func appStyleOverridesCanBeCodableSerialized() throws {
    let targetID1 = InsertionTargetID(rawValue: "com.apple.Terminal")
    let targetID2 = InsertionTargetID(rawValue: "com.microsoft.Word")

    var settings = AppSettings()
    settings.appStyleOverrides[targetID1] = .command
    settings.appStyleOverrides[targetID2] = .document

    let encoder = JSONEncoder()
    let encoded = try encoder.encode(settings)
    let decoder = JSONDecoder()
    let decoded = try decoder.decode(AppSettings.self, from: encoded)

    #expect(decoded.appStyleOverrides[targetID1] == .command)
    #expect(decoded.appStyleOverrides[targetID2] == .document)
  }

  @Test("AC-06: 同意状態は Codable でシリアライズできる")
  func consentStateCanBeCodableSerialized() throws {
    var settings = AppSettings()
    var consentState = ConsentState()
    consentState.grant(.transmission(.textRefinement(.claude)))
    consentState.grant(.transmission(.speechRecognition))
    settings.consentState = consentState

    let encoder = JSONEncoder()
    let encoded = try encoder.encode(settings)
    let decoder = JSONDecoder()
    let decoded = try decoder.decode(AppSettings.self, from: encoded)

    #expect(decoded.consentState.allows(.textRefinement(.claude)))
    #expect(decoded.consentState.allows(.speechRecognition))
    #expect(!decoded.consentState.allows(.textRefinement(.chatGPT)))
  }
}
