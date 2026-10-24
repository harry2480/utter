import Foundation
import Testing
import UtterCore

@testable import UtterPersistence

struct AppSettingsTests {
  private func decode(_ json: String) throws -> AppSettings {
    try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
  }

  private func roundTrip(_ settings: AppSettings) throws -> AppSettings {
    try JSONDecoder().decode(AppSettings.self, from: try JSONEncoder().encode(settings))
  }

  private func grantedConsent() -> ConsentState {
    var consentState = ConsentState()
    consentState.grant(.transmission(.textRefinement(.claude)))
    consentState.grant(.transmission(.speechRecognition))
    return consentState
  }

  private func priceTable() throws -> PriceTableSetting {
    PriceTableSetting(
      currencyCode: "usd",
      updatedOn: CalendarDay(year: 2026, month: 10, day: 1),
      prices: [
        try #require(
          ModelPriceSetting(
            model: "model-a", inputPerMillionTokens: Decimal(string: "0.8")!,
            outputPerMillionTokens: Decimal(4)))
      ])
  }

  // MARK: - 既定値

  @Test("AC-06: 既定値ですべて未同意で初期化される")
  func defaultConsentIsNotGranted() {
    let consentState = AppSettings().consentState

    for scope in ConsentScope.allCases {
      #expect(consentState.status(of: scope) == .notGranted)
    }
  }

  @Test("7章: 履歴は既定で無効")
  func historyDisabledByDefault() {
    #expect(AppSettings().historyEnabled == false)
  }

  @Test("REC-05: 最大録音時間の既定値は状態機械の既定値（暫定5分）とそろう")
  func defaultRecordingDurationMatchesSessionConfiguration() {
    #expect(AppSettings().maxRecordingDuration == 300)
    #expect(
      AppSettings.defaultMaxRecordingDuration
        == Double(SessionConfiguration.defaultMaxRecordingDuration.components.seconds))
  }

  @Test("AI-05: 単価表と月次予算は既定で未設定で、どのモデルの単価も返さない")
  func priceTableAndBudgetAreUnsetByDefault() {
    let settings = AppSettings()

    #expect(settings.priceTable == .empty)
    #expect(settings.priceTable.currencyCode == nil)
    #expect(settings.priceTable.updatedOn == nil)
    #expect(settings.priceTable.price(for: AppSettings.defaultRefinementModel) == nil)
    #expect(settings.monthlyBudget == nil)
  }

  @Test("AI-03: 整形の処理系は既定で Local Basic（クラウドへ送らない）")
  func refinementEngineDefaultsToLocalBasic() {
    #expect(AppSettings().refinementEngine == .localBasic)
  }

  @Test("REC-01, REC-02: 録音の操作方式は既定で Toggle、録音ショートカットは未設定")
  func recordingDefaults() {
    let settings = AppSettings()

    #expect(settings.recordingTrigger == .toggle)
    #expect(settings.recordingShortcut == nil)
  }

  @Test("2.2節, TXT-01: 入力モードは既定で Instant、整形モードは既定で Natural")
  func inputAndRefinementModeDefaults() {
    let settings = AppSettings()

    #expect(settings.inputMode == .instant)
    #expect(settings.refinementMode == .natural)
  }

  @Test("6章: モデル保持モードは既定でバランスモード、高速モードの保持は未許可")
  func modelRetentionDefaults() {
    let settings = AppSettings()

    #expect(settings.modelRetentionMode == .balanced)
    #expect(!settings.performanceRetentionAllowed)
  }

  @Test("AI-07: 整形用モデルの既定値は低遅延の小型モデル（Claude Haiku 5.5）")
  func defaultRefinementModelIsSmallModel() {
    #expect(AppSettings.defaultRefinementModel == "claude-haiku-5-5")
    #expect(AppSettings().refinementModel == "claude-haiku-5-5")
  }

  @Test("2.3節: 現在の版は 2")
  func currentVersionIs2() {
    #expect(AppSettings.currentVersion == 2)
    #expect(AppSettings().version == 2)
  }

  // MARK: - 保存・復元

  @Test("2.1節, 2.2節, 2.3節, 5章, 6章, 7章: すべての項目を保存・復元できる")
  func allPropertiesRoundTrip() throws {
    let budget = try #require(MonthlyBudgetSetting(limitAmount: Decimal(20), currencyCode: "USD"))
    let original = AppSettings(
      maxRecordingDuration: 600,
      recordingTrigger: .pushToTalk,
      recordingShortcut: KeyCombination(key: .space, modifiers: [.option]),
      inputMode: .realtimePreview,
      refinementMode: .structured,
      refinementEngine: .cloudAI,
      appStyleOverrides: ["com.apple.terminal": .command, "com.microsoft.word": .document],
      siteIdentificationAllowed: true,
      siteStyleOverrides: ["mail.example.com": .polite],
      refinementModel: "model-a",
      priceTable: try priceTable(),
      monthlyBudget: budget,
      consentState: grantedConsent(),
      historyEnabled: true,
      modelRetentionMode: .performance,
      performanceRetentionAllowed: true,
      excludedApps: ["com.example.Secret"])

    let decoded = try roundTrip(original)

    #expect(decoded == original)
    #expect(decoded.version == AppSettings.currentVersion)
    #expect(decoded.consentState.allows(.textRefinement(.claude)))
    #expect(decoded.consentState.allows(.speechRecognition))
    #expect(!decoded.consentState.allows(.textRefinement(.chatGPT)))
  }

  @Test(
    "REC-02: 修飾キー単独の録音ショートカットも保存・復元できる（割り当てられるかは利用時に判定する）")
  func modifierOnlyShortcutRoundTrips() throws {
    let fnOnly = try #require(KeyCombination(modifierOnly: [.function]))

    let decoded = try roundTrip(AppSettings(recordingShortcut: fnOnly))

    #expect(decoded.recordingShortcut == fnOnly)
    #expect(decoded.recordingShortcut?.isModifierOnly == true)
  }

  @Test("2.2節, TXT-01, 6章: 新しい項目は選んだ値をそれぞれ保存・復元できる")
  func newSelectionsRoundTrip() throws {
    for mode in ShortcutTriggerMode.allCases {
      #expect(try roundTrip(AppSettings(recordingTrigger: mode)).recordingTrigger == mode)
    }
    for mode in InputMode.allCases {
      #expect(try roundTrip(AppSettings(inputMode: mode)).inputMode == mode)
    }
    for mode in RefinementModeSetting.allCases {
      #expect(try roundTrip(AppSettings(refinementMode: mode)).refinementMode == mode)
    }
    for mode in ModelRetentionModeSetting.allCases {
      #expect(try roundTrip(AppSettings(modelRetentionMode: mode)).modelRetentionMode == mode)
    }
  }

  @Test("AC-06: 撤回した同意は撤回のまま復元される")
  func revokedConsentRoundTrips() throws {
    var consentState = grantedConsent()
    consentState.revoke(.transmission(.textRefinement(.claude)))

    let decoded = try roundTrip(AppSettings(consentState: consentState))

    #expect(decoded.consentState.status(of: .transmission(.textRefinement(.claude))) == .revoked)
    #expect(!decoded.consentState.allows(.textRefinement(.claude)))
  }

  @Test("AI-05: 単価は小数を丸めずに復元される")
  func priceTableKeepsDecimalPrecision() throws {
    let decoded = try roundTrip(AppSettings(priceTable: try priceTable()))
    let price = try #require(decoded.priceTable.price(for: "model-a"))

    #expect(price.inputPerMillionTokens == Decimal(string: "0.8"))
    #expect(price.outputPerMillionTokens == Decimal(4))
    #expect(decoded.priceTable.currencyCode == "USD")
    #expect(decoded.priceTable.updatedOn == CalendarDay(year: 2026, month: 10, day: 1))
  }

  // MARK: - 正規化

  @Test(
    "REC-05: 範囲（1〜3600 秒）外・非有限の最大録音時間は既定値に戻す",
    arguments: [0, -100, 0.5, 3600.5, 1e300, 1e-300, .nan, .infinity])
  func invalidRecordingDurationReverted(value: Double) {
    #expect(AppSettings(maxRecordingDuration: value).maxRecordingDuration == 300)

    var settings = AppSettings(maxRecordingDuration: 600)
    settings.maxRecordingDuration = value
    #expect(settings.maxRecordingDuration == 300)
  }

  @Test("CTX-02: アプリ別上書きは bundle ID を小文字にそろえ、空の bundle ID を除く")
  func appStyleOverridesAreNormalized() {
    var settings = AppSettings(appStyleOverrides: ["Com.Apple.Terminal": .command, "": .polite])
    #expect(settings.appStyleOverrides == ["com.apple.terminal": .command])

    settings.appStyleOverrides["COM.TINYSPECK.SLACKMACGAP"] = .concise
    #expect(settings.appStyleOverrides["com.tinyspeck.slackmacgap"] == .concise)

    let resolver = AppStyleResolver(overrides: settings.appStyleOverrides)
    #expect(resolver.style(forBundleID: "com.apple.Terminal") == .command)
  }

  @Test("AI-07: 空白だけの整形用モデル名は既定値に戻す", arguments: ["", "  ", "\n"])
  func blankRefinementModelReverted(model: String) {
    #expect(
      AppSettings(refinementModel: model).refinementModel == AppSettings.defaultRefinementModel)

    var settings = AppSettings(refinementModel: "model-a")
    settings.refinementModel = model
    #expect(settings.refinementModel == AppSettings.defaultRefinementModel)
  }

  @Test("7章: 除外アプリは入力した表記のまま持ち、空白だけの値と大文字・小文字違いの重複を除く")
  func excludedAppsAreNormalized() {
    let settings = AppSettings(excludedApps: [
      "com.example.A", " ", "COM.EXAMPLE.A", "com.example.B",
    ])

    #expect(settings.excludedApps == ["com.example.A", "com.example.B"])
    let policy = SensitiveInputPolicy(excludedApps: Set(settings.excludedApps))
    let context = SensitiveInputContext(
      secureField: .off, secureEventInput: .off, app: "com.example.a")
    #expect(policy.decide(context).reasons == [.excludedApp])
  }

  @Test("AI-05: 単価表の通貨コードは大文字にそろえ、空なら未設定")
  func priceTableCurrencyIsNormalized() {
    #expect(PriceTableSetting(currencyCode: " jpy ").currencyCode == "JPY")
    #expect(PriceTableSetting(currencyCode: "  ").currencyCode == nil)
  }

  @Test(
    "AI-05: ISO 4217 の形（英字3文字）でない通貨コードは単価表・予算とも受け付けない",
    arguments: ["US", "DOLLARS", "U$D", "１２３", "ＵＳＤ", "12A"])
  func malformedCurrencyCodeIsRejected(code: String) throws {
    #expect(PriceTableSetting(currencyCode: code).currencyCode == nil)
    #expect(MonthlyBudgetSetting(limitAmount: 1, currencyCode: code) == nil)
    let json = #"{"version": 1, "monthlyBudget": {"limitAmount": 1, "currencyCode": "\#(code)"}}"#
    #expect(try decode(json).monthlyBudget == nil)
  }

  @Test("AI-05: 通貨が未設定の単価表は、載っているモデルでも単価を返さない")
  func priceTableWithoutCurrencyIsNotUsable() throws {
    let price = try #require(
      ModelPriceSetting(model: "m", inputPerMillionTokens: 1, outputPerMillionTokens: 1))
    let table = PriceTableSetting(currencyCode: nil, prices: [price])

    #expect(table.price(for: "m") == nil)
  }

  @Test("AI-05: 同じモデルの単価が重複したら、どれが正しいか決められないため単価表から除く")
  func duplicateModelPricesAreRemoved() throws {
    let a1 = try #require(
      ModelPriceSetting(model: "a", inputPerMillionTokens: 1, outputPerMillionTokens: 1))
    let a2 = try #require(
      ModelPriceSetting(model: "a", inputPerMillionTokens: 2, outputPerMillionTokens: 2))
    let b = try #require(
      ModelPriceSetting(model: "b", inputPerMillionTokens: 3, outputPerMillionTokens: 3))
    let table = PriceTableSetting(currencyCode: "USD", prices: [a1, b, a2])

    #expect(table.prices == [b])
    #expect(table.price(for: "a") == nil)
  }

  @Test("AI-05: 空のモデル名・負・非数の単価は作れない")
  func invalidModelPriceIsRejected() {
    #expect(
      ModelPriceSetting(model: "", inputPerMillionTokens: 1, outputPerMillionTokens: 1) == nil)
    #expect(
      ModelPriceSetting(model: "m", inputPerMillionTokens: -1, outputPerMillionTokens: 1) == nil)
    #expect(
      ModelPriceSetting(model: "m", inputPerMillionTokens: 1, outputPerMillionTokens: -1) == nil)
    #expect(
      ModelPriceSetting(model: "m", inputPerMillionTokens: .nan, outputPerMillionTokens: 1) == nil)
  }

  @Test("AI-05: 単価表の更新日は月・日の範囲外を作れない")
  func invalidCalendarDayIsRejected() {
    #expect(CalendarDay(year: 2026, month: 13, day: 1) == nil)
    #expect(CalendarDay(year: 2026, month: 0, day: 1) == nil)
    #expect(CalendarDay(year: 2026, month: 1, day: 32) == nil)
    #expect(CalendarDay(year: 2026, month: 1, day: 0) == nil)
  }

  @Test("AI-04, AI-05: 月次予算は 0（費用をかけない）を許し、負・非数・通貨なしは作れない")
  func monthlyBudgetValidation() {
    #expect(MonthlyBudgetSetting(limitAmount: 0, currencyCode: "JPY")?.limitAmount == 0)
    #expect(MonthlyBudgetSetting(limitAmount: 100, currencyCode: " usd ")?.currencyCode == "USD")
    #expect(MonthlyBudgetSetting(limitAmount: -1, currencyCode: "JPY") == nil)
    #expect(MonthlyBudgetSetting(limitAmount: .nan, currencyCode: "JPY") == nil)
    #expect(MonthlyBudgetSetting(limitAmount: 100, currencyCode: " ") == nil)
  }

  // MARK: - 壊れた値・未知の版

  @Test("2.3節: 不足した値は既定値で復元される")
  func missingValuesRevertToDefaults() throws {
    #expect(try decode(#"{"version": 1}"#) == AppSettings())
    #expect(try decode(#"{"version": 2}"#) == AppSettings())
  }

  @Test("2.3節: 版番号がない保存値は版 1 として読み、現在の版に移行する")
  func missingVersionIsReadAsVersion1() throws {
    let settings = try decode(#"{"maxRecordingDuration": 600}"#)

    #expect(settings.version == AppSettings.currentVersion)
    #expect(settings.maxRecordingDuration == 600)
  }

  @Test("2.3節, AC-06: 版 1 の保存値は値を保ったまま版 2 に移行し、追加した項目は既定値になる")
  func version1MigratesToVersion2() throws {
    let budget = try #require(MonthlyBudgetSetting(limitAmount: Decimal(20), currencyCode: "USD"))
    let version1 = AppSettings(
      maxRecordingDuration: 600,
      refinementEngine: .cloudAI,
      appStyleOverrides: ["com.apple.terminal": .command],
      refinementModel: "claude-3-5-sonnet-20241022",
      priceTable: try priceTable(),
      monthlyBudget: budget,
      consentState: grantedConsent(),
      historyEnabled: true,
      excludedApps: ["com.example.Secret"])
    // 版 1 で保存した形（版 2 で追加した項目がなく、version が 1）。単価の小数を丸めないよう文字列で組み立てる
    func json<T: Encodable>(_ value: T) throws -> String {
      String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }
    let stored = """
      {
        "version": 1,
        "maxRecordingDuration": 600,
        "refinementEngine": "cloudAI",
        "appStyleOverrides": \(try json(version1.appStyleOverrides)),
        "refinementModel": "claude-3-5-sonnet-20241022",
        "priceTable": \(try json(version1.priceTable)),
        "monthlyBudget": \(try json(budget)),
        "consentState": \(try json(version1.consentState)),
        "historyEnabled": true,
        "excludedApps": ["com.example.Secret"]
      }
      """

    let migrated = try decode(stored)

    var expected = version1
    expected.refinementModel = AppSettings.defaultRefinementModel
    #expect(migrated == expected)
    #expect(migrated.version == 2)
    #expect(migrated.consentState.allows(.textRefinement(.claude)))
    #expect(migrated.recordingTrigger == .toggle)
    #expect(migrated.recordingShortcut == nil)
    #expect(migrated.inputMode == .instant)
    #expect(migrated.refinementMode == .natural)
    #expect(migrated.modelRetentionMode == .balanced)
    #expect(!migrated.performanceRetentionAllowed)
  }

  @Test("AI-07: 版 1 の旧既定モデル名（提供終了）は新しい既定値に移行し、利用者が選んだモデル名は保つ")
  func version1DefaultModelIsMigrated() throws {
    let oldDefault = try decode(
      #"{"version": 1, "refinementModel": "claude-3-5-sonnet-20241022"}"#)
    let chosen = try decode(#"{"version": 1, "refinementModel": "model-a"}"#)

    #expect(oldDefault.refinementModel == AppSettings.defaultRefinementModel)
    #expect(chosen.refinementModel == "model-a")
  }

  @Test("AI-07: 版 2 で保存したモデル名は、旧既定値と同じでも書き換えない（利用者が選んだ値）")
  func version2ModelIsKept() throws {
    let settings = try decode(
      #"{"version": 2, "refinementModel": "claude-3-5-sonnet-20241022"}"#)

    #expect(settings.refinementModel == "claude-3-5-sonnet-20241022")
  }

  @Test("2.3節, 6章: 版 1 の保存値に版 2 の項目があっても読まない（版 1 にない許可を作らない）")
  func version1IgnoresVersion2Fields() throws {
    let settings = try decode(
      """
      {
        "version": 1,
        "historyEnabled": true,
        "recordingTrigger": "pushToTalk",
        "recordingShortcut": {"key": "space", "modifiers": 2},
        "inputMode": "realtimePreview",
        "refinementMode": "raw",
        "modelRetentionMode": "performance",
        "performanceRetentionAllowed": true
      }
      """)

    #expect(settings == AppSettings(historyEnabled: true))
  }

  @Test(
    "2.3節, AC-06: 未知の版は既定値で復元し、同意は未同意に倒す",
    arguments: ["3", "999", "0", "-1", "\"1\"", "\"2\"", "null", "1.5", "2.5"])
  func unknownVersionRevertsToDefaults(version: String) throws {
    let stored = try JSONEncoder().encode(
      AppSettings(
        maxRecordingDuration: 600, recordingTrigger: .pushToTalk,
        recordingShortcut: KeyCombination(key: .space, modifiers: [.option]),
        inputMode: .realtimePreview, refinementMode: .raw, refinementEngine: .cloudAI,
        consentState: grantedConsent(), historyEnabled: true, modelRetentionMode: .performance,
        performanceRetentionAllowed: true))
    var object = try #require(JSONSerialization.jsonObject(with: stored) as? [String: Any])
    object["version"] = try JSONSerialization.jsonObject(
      with: Data(version.utf8), options: .fragmentsAllowed)
    let json = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)

    let settings = try decode(json)

    #expect(settings == AppSettings())
    #expect(!settings.consentState.allows(.textRefinement(.claude)))
  }

  @Test("2.3節: 型が合わない値は、その項目だけ既定値に戻す", arguments: [1, 2])
  func mismatchedTypesRevertPerField(version: Int) throws {
    let settings = try decode(
      """
      {
        "version": \(version),
        "maxRecordingDuration": "long",
        "refinementEngine": "unknownEngine",
        "appStyleOverrides": ["not", "a", "map"],
        "refinementModel": 42,
        "priceTable": "free",
        "monthlyBudget": {"limitAmount": "a lot", "currencyCode": "USD"},
        "historyEnabled": "yes",
        "excludedApps": "com.example.app"
      }
      """)

    #expect(settings == AppSettings())
  }

  @Test("2.1節, 2.2節, TXT-01, 6章: 版 2 で追加した項目も、型が合わなければその項目だけ既定値に戻す")
  func mismatchedVersion2FieldsRevertPerField() throws {
    let settings = try decode(
      """
      {
        "version": 2,
        "recordingTrigger": "hold",
        "recordingShortcut": {"key": "", "modifiers": 0},
        "inputMode": "realtimeDirect",
        "refinementMode": 1,
        "modelRetentionMode": "turbo",
        "performanceRetentionAllowed": "yes"
      }
      """)

    #expect(settings == AppSettings())
  }

  @Test("2.1節, 6章: 版 2 の壊れた項目があっても、ほかの項目は復元される")
  func validVersion2FieldsSurviveBrokenNeighbours() throws {
    let settings = try decode(
      """
      {
        "version": 2,
        "historyEnabled": true,
        "recordingTrigger": "pushToTalk",
        "recordingShortcut": {"key": "space", "modifiers": 64},
        "inputMode": "realtimePreview",
        "refinementMode": "structured",
        "modelRetentionMode": "performance",
        "performanceRetentionAllowed": null
      }
      """)

    #expect(settings.historyEnabled)
    #expect(settings.recordingTrigger == .pushToTalk)
    // 定義にない修飾キーを含むショートカットは未設定に戻す（割り当てを推測で作らない）
    #expect(settings.recordingShortcut == nil)
    #expect(settings.inputMode == .realtimePreview)
    #expect(settings.refinementMode == .structured)
    #expect(settings.modelRetentionMode == .performance)
    #expect(!settings.performanceRetentionAllowed)
  }

  @Test("2.3節: 型が合わない項目があっても、ほかの項目は復元される", arguments: [1, 2])
  func validFieldsSurviveBrokenNeighbours(version: Int) throws {
    let settings = try decode(
      """
      {
        "version": \(version),
        "maxRecordingDuration": "long",
        "refinementEngine": "cloudAI",
        "historyEnabled": true
      }
      """)

    #expect(settings.maxRecordingDuration == 300)
    #expect(settings.refinementEngine == .cloudAI)
    #expect(settings.historyEnabled)
  }

  @Test(
    "AC-06: 壊れた同意状態は未同意に倒す（版 1・版 2）",
    arguments: [1, 2],
    [
      #"null"#,
      #""granted""#,
      #"{"statuses": "granted"}"#,
      #"{"statuses": [{"transmission": {"_0": {"textRefinement": {"_0": "claude"}}}}, "maybe"]}"#,
    ])
  func corruptedConsentStateRevertsToNotGranted(version: Int, consent: String) throws {
    let settings = try decode(
      #"{"version": \#(version), "historyEnabled": true, "consentState": \#(consent)}"#)

    for scope in ConsentScope.allCases {
      #expect(settings.consentState.status(of: scope) == .notGranted)
    }
    #expect(settings.historyEnabled)
  }

  @Test("REC-05: 復元時も0以下の録音時間は既定値に戻す")
  func invalidRecordingDurationRevertedOnDecode() throws {
    #expect(try decode(#"{"version": 1, "maxRecordingDuration": 0}"#).maxRecordingDuration == 300)
    #expect(try decode(#"{"version": 1, "maxRecordingDuration": -5}"#).maxRecordingDuration == 300)
    #expect(
      try decode(#"{"version": 1, "maxRecordingDuration": 1e300}"#).maxRecordingDuration == 300)
    #expect(
      try decode(#"{"version": 1, "maxRecordingDuration": 1e-300}"#).maxRecordingDuration == 300)
  }

  @Test("REC-05: 範囲内の最大録音時間は状態機械の設定に変換できる", arguments: [1.0, 300, 3600])
  func recordingDurationConvertsToSessionConfiguration(value: Double) throws {
    let settings = AppSettings(maxRecordingDuration: value)
    let configuration = try SessionConfiguration(
      maxRecordingDuration: .seconds(settings.maxRecordingDuration))

    #expect(settings.maxRecordingDuration == value)
    #expect(configuration.maxRecordingDuration == .seconds(value))
  }

  @Test("2.3節, AC-06: #76 の形式で保存された値は移行せず、読める項目と同意だけを復元する")
  func legacyFormatIsNotMigrated() throws {
    var consentState = ConsentState()
    consentState.grant(.transmission(.textRefinement(.claude)))
    let consent = String(decoding: try JSONEncoder().encode(consentState), as: UTF8.self)
    let settings = try decode(
      """
      {
        "version": 1,
        "maxRecordingDuration": 600,
        "refinementMode": "cloudAI",
        "appStyleOverrides": [{"rawValue": "com.apple.Terminal"}, {"command": {}}],
        "refinementModel": "model-a",
        "pricePerMillionTokens": {"model-a": 3.0},
        "priceTableUpdatedAt": 0,
        "monthlyBudget": 25.0,
        "consentState": \(consent),
        "historyEnabled": true
      }
      """)

    #expect(settings.consentState.allows(.textRefinement(.claude)))
    #expect(settings.maxRecordingDuration == 600)
    #expect(settings.refinementModel == "model-a")
    #expect(settings.historyEnabled)
    #expect(settings.refinementEngine == .localBasic)
    #expect(settings.appStyleOverrides.isEmpty)
    #expect(settings.priceTable == .empty)
    #expect(settings.monthlyBudget == nil)
  }

  @Test("AI-05, AI-07: モデル名は前後の空白を除いて持つ")
  func modelNamesAreTrimmed() throws {
    #expect(AppSettings(refinementModel: " model-a \n").refinementModel == "model-a")
    let price = try #require(
      ModelPriceSetting(model: " model-a ", inputPerMillionTokens: 1, outputPerMillionTokens: 1))
    #expect(price.model == "model-a")
    #expect(PriceTableSetting(currencyCode: "USD", prices: [price]).price(for: "model-a") != nil)
    #expect(
      ModelPriceSetting(model: "  ", inputPerMillionTokens: 1, outputPerMillionTokens: 1) == nil)
  }

  @Test("AI-05: 更新日が未設定でも単価は返す（UtterAI の PriceTable への変換は呼び出し側が判断する）")
  func priceIsReturnedWithoutUpdateDate() throws {
    let price = try #require(
      ModelPriceSetting(model: "m", inputPerMillionTokens: 1, outputPerMillionTokens: 1))
    let table = PriceTableSetting(currencyCode: "USD", updatedOn: nil, prices: [price])

    #expect(table.price(for: "m") == price)
  }

  @Test("AI-04, AI-05: 壊れた月次予算は未設定に戻す（上限を勝手に作らない）")
  func corruptedBudgetBecomesUnset() throws {
    let negative = try decode(
      #"{"version": 1, "monthlyBudget": {"limitAmount": -10, "currencyCode": "USD"}}"#)
    let noCurrency = try decode(
      #"{"version": 1, "monthlyBudget": {"limitAmount": 10, "currencyCode": ""}}"#)

    #expect(negative.monthlyBudget == nil)
    #expect(noCurrency.monthlyBudget == nil)
  }

  @Test("AI-05: 壊れた単価の行だけを除き、ほかの行と通貨・更新日は復元する")
  func corruptedPriceRowsAreDropped() throws {
    let settings = try decode(
      """
      {
        "version": 1,
        "priceTable": {
          "currencyCode": "USD",
          "updatedOn": {"year": 2026, "month": 10, "day": 1},
          "prices": [
            {"model": "ok", "inputPerMillionTokens": 1, "outputPerMillionTokens": 2},
            {"model": "", "inputPerMillionTokens": 1, "outputPerMillionTokens": 2},
            {"model": "negative", "inputPerMillionTokens": -1, "outputPerMillionTokens": 2},
            "garbage",
            {"model": "ok2", "inputPerMillionTokens": 3, "outputPerMillionTokens": 4}
          ]
        }
      }
      """)

    #expect(settings.priceTable.prices.map(\.model) == ["ok", "ok2"])
    #expect(settings.priceTable.currencyCode == "USD")
    #expect(settings.priceTable.updatedOn == CalendarDay(year: 2026, month: 10, day: 1))
  }

  @Test("AI-05: 範囲外の更新日は未設定に戻し、単価は残す")
  func corruptedUpdateDateBecomesUnset() throws {
    let settings = try decode(
      """
      {
        "version": 1,
        "priceTable": {
          "currencyCode": "USD",
          "updatedOn": {"year": 2026, "month": 13, "day": 1},
          "prices": [{"model": "ok", "inputPerMillionTokens": 1, "outputPerMillionTokens": 2}]
        }
      }
      """)

    #expect(settings.priceTable.updatedOn == nil)
    #expect(settings.priceTable.price(for: "ok") != nil)
  }

  @Test("CTX-02: 読めないスタイルの上書きだけを除く")
  func corruptedStyleOverridesAreDropped() throws {
    let settings = try decode(
      """
      {
        "version": 1,
        "appStyleOverrides": {
          "com.apple.Terminal": {"command": {}},
          "com.example.app": {"unknownStyle": {}},
          "com.example.other": 3
        }
      }
      """)

    #expect(settings.appStyleOverrides == ["com.apple.terminal": .command])
  }

  @Test("7章: 文字列でない除外アプリだけを除く")
  func corruptedExcludedAppsAreDropped() throws {
    let settings = try decode(
      #"{"version": 1, "excludedApps": ["com.example.a", 3, null, "com.example.b"]}"#)

    #expect(settings.excludedApps == ["com.example.a", "com.example.b"])
  }

  @Test("2.3節: オブジェクトでない保存値は既定値で復元される")
  func nonObjectRevertsToDefaults() throws {
    #expect(try decode("[1, 2, 3]") == AppSettings())
    #expect(try decode(#""settings""#) == AppSettings())
  }

  // MARK: - サイト別のスタイル（CTX-02）

  @Test("CTX-02: サイト単位の識別は既定で許可せず、サイト別の上書きもない")
  func siteIdentificationIsDisabledByDefault() {
    let settings = AppSettings()

    #expect(!settings.siteIdentificationAllowed)
    #expect(settings.siteStyleOverrides.isEmpty)
    #expect(!settings.contextStyleResolver.site.needsSiteHost)
  }

  @Test("CTX-02: サイト別の上書きのキーはホスト名に正規化し、正規化できないキーは除く")
  func siteOverridesAreNormalized() {
    var settings = AppSettings(
      siteStyleOverrides: [
        "WWW.Example.com.": .polite, "example.com:8080": .technical, "": .concise,
      ])
    #expect(settings.siteStyleOverrides == ["example.com": .polite])

    settings.siteStyleOverrides["Docs.Example.com"] = .document
    #expect(settings.siteStyleOverrides["docs.example.com"] == .document)
    #expect(settings.siteStyleOverrides["Docs.Example.com"] == nil)
  }

  @Test("CTX-02: 許可があるときだけサイト別の上書きをアプリ別より優先する")
  func contextStyleResolverUsesSiteOverridesOnlyWhenAllowed() throws {
    let host = try #require(SiteHost(host: "mail.example.com"))
    var settings = AppSettings(
      appStyleOverrides: ["com.apple.Safari": .document],
      siteStyleOverrides: ["mail.example.com": .polite])

    #expect(
      settings.contextStyleResolver.style(forBundleID: "com.apple.safari", siteHost: host)
        == .document)

    settings.siteIdentificationAllowed = true
    #expect(
      settings.contextStyleResolver.style(forBundleID: "com.apple.safari", siteHost: host)
        == .polite)
    // 既定の対応表はアプリ別の上書きの下に残る（CTX-01）
    #expect(settings.contextStyleResolver.style(forBundleID: "com.apple.mail") == .polite)
  }

  @Test("CTX-02: サイト別の項目がない版 2 の保存値は、許可なし・上書きなしで読む")
  func version2WithoutSiteFieldsUsesDefaults() throws {
    let settings = try decode(#"{"version": 2, "historyEnabled": true}"#)

    #expect(settings.historyEnabled)
    #expect(!settings.siteIdentificationAllowed)
    #expect(settings.siteStyleOverrides.isEmpty)
  }

  @Test("CTX-02: 読めない許可は未許可に倒し、読めない・正規化できない上書きだけを除く")
  func corruptedSiteFieldsRevertPerEntry() throws {
    let settings = try decode(
      """
      {
        "version": 2,
        "siteIdentificationAllowed": "yes",
        "siteStyleOverrides": {
          "Example.com": {"polite": {}},
          "bad host": {"concise": {}},
          "docs.example.com": {"unknownStyle": {}}
        }
      }
      """)

    #expect(!settings.siteIdentificationAllowed)
    #expect(settings.siteStyleOverrides == ["example.com": .polite])
  }

  @Test("CTX-02: 版 1 の保存値にサイト別の項目があっても読まない")
  func version1IgnoresSiteFields() throws {
    let settings = try decode(
      #"{"version": 1, "siteIdentificationAllowed": true, "siteStyleOverrides": {"example.com": {"polite": {}}}}"#
    )

    #expect(!settings.siteIdentificationAllowed)
    #expect(settings.siteStyleOverrides.isEmpty)
  }

  // MARK: - 秘密情報

  @Test("AC-06, 7章: 保存する項目は決まったものだけで、API キー・トークンを入れる項目を持たない")
  func storedKeysAreFixed() throws {
    let budget = try #require(MonthlyBudgetSetting(limitAmount: 1, currencyCode: "USD"))
    let data = try JSONEncoder().encode(
      AppSettings(recordingShortcut: KeyCombination(key: .space), monthlyBudget: budget))
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

    // 項目を足すときは、秘密情報（API キー・OAuth トークン）でないことを確認してからここに足す
    #expect(
      Set(object.keys) == [
        "version", "maxRecordingDuration", "recordingTrigger", "recordingShortcut", "inputMode",
        "refinementMode", "refinementEngine", "appStyleOverrides", "siteIdentificationAllowed",
        "siteStyleOverrides", "refinementModel",
        "priceTable", "monthlyBudget", "consentState", "historyEnabled", "modelRetentionMode",
        "performanceRetentionAllowed", "excludedApps",
      ])
    #expect(Set(object.keys) == Set(AppSettings.CodingKeys.allCases.map(\.stringValue)))
  }
}
