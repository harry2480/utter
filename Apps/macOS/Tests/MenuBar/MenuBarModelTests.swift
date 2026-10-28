import Foundation
import Testing
import UtterAI
import UtterCore
import UtterPersistence
import UtterSpeech

@MainActor
struct MenuBarModelTests {
  private let suite: TestDefaults
  private let usageStore: MonthlyUsageStore
  private let calendar: Calendar
  /// 2026-10-25 12:00（Asia/Tokyo）
  private let now: Date

  init() throws {
    suite = try TestDefaults()
    usageStore = MonthlyUsageStore(database: try UtterDatabase.inMemory())
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "Asia/Tokyo"))
    self.calendar = calendar
    now = try #require(
      calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 12)))
  }

  private var store: AppSettingsStore { AppSettingsStore(defaults: suite.defaults) }

  private func makeModel(
    sttEngine: STTEngineKind? = nil, modelAssets: (any SpeechModelAssets)? = nil
  ) -> MenuBarModel {
    let usageStore = self.usageStore
    let now = self.now
    return MenuBarModel(
      store: store, openUsageStore: { usageStore }, sttEngine: sttEngine, modelAssets: modelAssets,
      now: { now }, calendar: calendar)
  }

  private func makeSettingsModel() -> SettingsModel {
    let usageStore = self.usageStore
    let now = self.now
    return SettingsModel(
      store: store, openUsageStore: { usageStore }, now: { now }, calendar: calendar)
  }

  private func consent(_ transmissions: CloudTransmission...) -> ConsentState {
    var consent = ConsentState()
    for transmission in transmissions {
      consent.grant(.transmission(transmission))
    }
    return consent
  }

  // MARK: 状態

  @Test(
    "#197: メニューの先頭にセッションの状態を出す",
    arguments: [
      (SessionPhase.idle, "状態: 待機中"),
      (.recording, "状態: 録音中"),
      (.recognizing, "状態: 認識中"),
      (.refining, "状態: 整形中"),
      (.inserting, "状態: 入力中"),
      (.error(.recognition), "状態: 認識に失敗しました"),
    ])
  func phaseTitle(_ phase: SessionPhase, _ expected: String) {
    #expect(MenuBarModel.phaseTitle(phase) == expected)
  }

  // MARK: 入力モード

  @Test("2.2節: 入力モードを Instant と Realtime Preview から選び、設定画面と同じ保存先に保存する")
  func selectInputMode() throws {
    try store.save(AppSettings(consentState: consent(.textRefinement(.claude))))
    let model = makeModel()
    #expect(model.inputModeChoices == [.instant, .realtimePreview])

    #expect(model.select(inputMode: .realtimePreview))

    let loaded = store.load()
    #expect(loaded.inputMode == .realtimePreview)
    // メニューで変えない項目（ほかの画面の同意）は残す
    #expect(loaded.consentState.allows(.textRefinement(.claude)))
    #expect(model.settings.inputMode == .realtimePreview)
    #expect(!model.saveFailed)
  }

  @Test("2.2節: 設定画面で Realtime Direct を選んでいるときは、選択中の値としてメニューにも並べる")
  func realtimeDirectIsListedOnlyWhenSelected() throws {
    try store.save(AppSettings(inputMode: .realtimeDirect))
    let model = makeModel()
    #expect(model.inputModeChoices == [.instant, .realtimePreview, .realtimeDirect])

    #expect(model.select(inputMode: .instant))
    #expect(model.inputModeChoices == [.instant, .realtimePreview])
  }

  // MARK: 文体

  @Test(
    "TXT-01: 文体（Raw / Natural / Structured）を保存する",
    arguments: RefinementModeSetting.allCases)
  func selectRefinementMode(_ mode: RefinementModeSetting) {
    let model = makeModel()

    #expect(model.select(refinementMode: mode))

    #expect(store.load().refinementMode == mode)
    #expect(model.settings.refinementMode == mode)
  }

  @Test("CTX-01: 前面のアプリの自動スタイルを、設定画面のアプリ別の上書きを含めて判定する")
  func autoStyleUsesAppOverrides() throws {
    try store.save(AppSettings(appStyleOverrides: ["com.example.editor": .technical]))
    let model = makeModel()

    #expect(model.autoStyle(forBundleID: "com.example.editor") == .technical)
    #expect(model.autoStyle(forBundleID: "com.example.unknown") == .standard)
    #expect(model.autoStyle(forBundleID: nil) == .standard)

    let app = MenuBarModel.FrontmostApp(bundleID: "com.example.editor", name: "Editor")
    model.updateFrontmostApp(app)
    #expect(model.frontmostApp == app)
  }

  // MARK: 整形の実行先

  @Test("AC-06: 同意のない送信先を選ぶと、保存して同意の画面へ案内し、同意は変えない")
  func providerWithoutConsentRequiresConsent() {
    let model = makeModel()

    #expect(model.select(provider: .claude) == .consentRequired)

    let loaded = store.load()
    #expect(loaded.refinementEngine == .cloudAI)
    #expect(loaded.cloudRefinementProvider == .claude)
    #expect(!loaded.consentState.allows(.textRefinement(.claude)))
    #expect(model.provider == .claude)
    #expect(!model.hasConsent(for: .claude))
  }

  @Test("AC-06: 同意のある送信先は、そのまま保存する")
  func providerWithConsentIsSaved() throws {
    try store.save(AppSettings(consentState: consent(.textRefinement(.chatGPT))))
    let model = makeModel()

    #expect(model.select(provider: .chatGPTSignIn) == .saved)

    let loaded = store.load()
    #expect(loaded.refinementEngine == .cloudAI)
    #expect(loaded.cloudRefinementProvider == .chatGPTSignIn)
    // Claude への同意は ChatGPT への同意にならない
    #expect(!model.hasConsent(for: .claude))
  }

  @Test("AI-03: Local Basic は同意なしで選べ、クラウドの送信先は変えない（設定画面と同じ）")
  func localBasicKeepsCloudProvider() throws {
    try store.save(
      AppSettings(refinementEngine: .cloudAI, cloudRefinementProvider: .chatGPTSignIn))
    let model = makeModel()

    #expect(model.select(provider: .localBasic) == .saved)

    let loaded = store.load()
    #expect(loaded.refinementEngine == .localBasic)
    #expect(loaded.cloudRefinementProvider == .chatGPTSignIn)
    #expect(model.provider == .localBasic)
  }

  @Test("#50: 準備中の OpenAI API キー方式は選べず、何も保存しない")
  func openAIAPIKeyIsNotSelectable() throws {
    let saved = AppSettings(refinementEngine: .cloudAI, cloudRefinementProvider: .claude)
    try store.save(saved)
    let model = makeModel()

    #expect(model.select(provider: .openAIAPIKey) == .notSelectable)

    #expect(store.load() == saved)
    #expect(model.provider == .claude)
  }

  @Test("AC-06: 文字を送る送信先にだけ「文字を送信」と示し、同意がなければ同意が要ることを添える")
  func providerTitles() {
    #expect(MenuBarModel.providerTitle(.localBasic, hasConsent: true) == "Local Basic（オフライン）")
    #expect(MenuBarModel.providerTitle(.claude, hasConsent: true) == "Claude（文字を送信）")
    #expect(MenuBarModel.providerTitle(.claude, hasConsent: false) == "Claude（文字を送信・同意が必要）")
    #expect(
      MenuBarModel.providerTitle(.chatGPTSignIn, hasConsent: false)
        == "ChatGPT（Sign in with ChatGPT）（文字を送信・同意が必要）")
    #expect(
      MenuBarModel.providerTitle(.openAIAPIKey, hasConsent: false)
        == "ChatGPT（OpenAI API キー方式）（文字を送信・準備中）")
    let sending = RefinementProviderChoice.allCases.filter { MenuBarModel.sendsText($0) }
    #expect(sending == [.claude, .chatGPTSignIn, .openAIAPIKey])
  }

  // MARK: 設定画面との同期

  @Test("#197: 設定画面で保存した値を、メニューで読み直す")
  func menuReloadsSettingsWindowChanges() {
    let model = makeModel()
    let settings = makeSettingsModel()
    settings.form.inputMode = .realtimePreview
    settings.form.refinementMode = .structured
    #expect(settings.save())

    #expect(model.reload())

    #expect(model.settings.inputMode == .realtimePreview)
    #expect(model.settings.refinementMode == .structured)
    // 変わっていなければ読み直さない
    #expect(!model.reload())
  }

  @Test("#197: メニューで変えた値を、開いたままの設定画面に取り込み、設定画面の保存で戻さない")
  func settingsWindowAdoptsMenuChanges() {
    let settings = makeSettingsModel()
    let model = makeModel()

    #expect(model.select(inputMode: .realtimePreview))
    #expect(model.select(refinementMode: .raw))
    #expect(model.select(provider: .claude) == .consentRequired)
    settings.adoptExternalChanges()

    #expect(settings.form.inputMode == .realtimePreview)
    #expect(settings.form.refinementMode == .raw)
    #expect(settings.form.provider == .claude)

    settings.form.recordingTrigger = .pushToTalk
    #expect(settings.save())
    let loaded = store.load()
    #expect(loaded.inputMode == .realtimePreview)
    #expect(loaded.refinementMode == .raw)
    #expect(loaded.refinementEngine == .cloudAI)
    #expect(loaded.recordingTrigger == .pushToTalk)
  }

  @Test("#197: 設定画面で編集中の項目は、メニューで変えた値で上書きしない")
  func settingsWindowKeepsEditedValues() {
    let settings = makeSettingsModel()
    settings.form.inputMode = .realtimeDirect
    let model = makeModel()

    #expect(model.select(inputMode: .realtimePreview))
    #expect(model.select(refinementMode: .structured))
    settings.adoptExternalChanges()

    #expect(settings.form.inputMode == .realtimeDirect)
    #expect(settings.form.refinementMode == .structured)
  }

  @Test("#197: 設定画面の保存は、開いた後にメニューで変えた値を、編集していなければ残す")
  func settingsSaveKeepsMenuChangesWithoutAdopting() {
    let settings = makeSettingsModel()
    let model = makeModel()
    #expect(model.select(refinementMode: .raw))

    // 通知を受ける前に保存しても、メニューで変えた値を戻さない
    #expect(settings.save())

    #expect(store.load().refinementMode == .raw)
  }

  // MARK: 認識モデルの状態

  @Test("PERM-03: 認識モデルの状態を、取得はせずに確かめて出す")
  func speechModelStatus() async {
    let assets = StubSpeechModelAssets(availability: .notInstalled)
    let model = makeModel(sttEngine: .speechAnalyzer, modelAssets: assets)
    let before = MenuBarModel.speechRecognitionText(
      engine: model.sttEngine, cloudEnabled: false, availability: model.speechModelAvailability)
    #expect(before == "音声認識: SpeechAnalyzer（モデル: 確認中）")

    await model.refreshSpeechModel()

    #expect(model.speechModelAvailability == .notInstalled)
    #expect(assets.installCount == 0)
    let after = MenuBarModel.speechRecognitionText(
      engine: model.sttEngine, cloudEnabled: false, availability: model.speechModelAvailability)
    #expect(after == "音声認識: SpeechAnalyzer（モデル: 未取得）")
  }

  @Test("4章: 音声認識が未設定・クラウド STT を選んでいるときの表示")
  func speechRecognitionTexts() {
    #expect(
      MenuBarModel.speechRecognitionText(engine: nil, cloudEnabled: false, availability: nil)
        == "音声認識: 未設定")
    #expect(
      MenuBarModel.speechRecognitionText(
        engine: .speechAnalyzer, cloudEnabled: true, availability: .installed)
        == "音声認識: クラウド（OpenAI へ音声を送る設定）")
    #expect(
      MenuBarModel.speechRecognitionText(
        engine: .speechAnalyzer, cloudEnabled: false, availability: .installed)
        == "音声認識: SpeechAnalyzer（モデル: 取得済み）")
  }

  // MARK: 推定費用

  @Test("AI-05: 今月の推定費用と上限を出す")
  func costShowsEstimateAndLimit() async throws {
    try store.save(
      AppSettings(
        refinementEngine: .cloudAI,
        priceTable: PriceTableSetting(
          currencyCode: "USD", updatedOn: CalendarDay(year: 2026, month: 10, day: 1)),
        monthlyBudget: MonthlyBudgetSetting(limitAmount: 10, currencyCode: "USD")))
    let spent = try #require(Decimal(string: "2.5"))
    try usageStore.record(spent, currencyCode: "USD", in: UsageMonth(year: 2026, month: 10))
    let model = makeModel()

    await model.refreshCost()

    guard case .summary(let summary) = model.cost else {
      Issue.record("推定費用を表示していない: \(model.cost)")
      return
    }
    #expect(summary.estimatedSpent == spent)
    #expect(summary.limitAmount == 10)
    let locale = Locale(identifier: "en_US")
    let style = Decimal.FormatStyle.Currency(code: "USD", locale: locale)
    #expect(
      MenuBarModel.costText(model.cost, locale: locale)
        == "今月の推定費用: \(spent.formatted(style)) / 上限 \(Decimal(10).formatted(style))")
    #expect(MenuBarModel.costEstimateNote.contains("推定値"))
  }

  @Test("AI-05: 予算が未設定なら、推定費用を 0 として出さない")
  func costUnavailableIsNotShownAsZero() async {
    let model = makeModel()

    await model.refreshCost()

    #expect(model.cost == .unavailable(.budgetNotSet))
    #expect(MenuBarModel.costText(model.cost) == "今月の推定費用: 月次予算が未設定")
    #expect(MenuBarModel.costText(.unreadable) == "今月の推定費用: 記録を読み込めません")
  }
}
