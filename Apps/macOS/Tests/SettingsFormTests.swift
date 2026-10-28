import Foundation
import Testing
import UtterCore
import UtterPersistence

struct SettingsFormTests {
  private func price(_ model: String, _ input: Decimal, _ output: Decimal) throws
    -> ModelPriceSetting
  {
    try #require(
      ModelPriceSetting(model: model, inputPerMillionTokens: input, outputPerMillionTokens: output))
  }

  private func issues(_ form: SettingsForm, base: AppSettings = AppSettings()) -> [SettingsIssue] {
    do throws(SettingsValidationError) {
      _ = try form.applied(to: base)
      return []
    } catch {
      return error.issues
    }
  }

  // MARK: - 保存と復元

  @Test("AC-05, AI-05, CTX-02, REC-01, REC-05: 保存済みの値から作った入力欄をそのまま保存すると同じ設定になる")
  func formRoundTripsSettings() throws {
    let settings = AppSettings(
      maxRecordingDuration: 600,
      recordingTrigger: .pushToTalk,
      recordingShortcut: KeyCombination(key: .space, modifiers: [.option, .command]),
      inputMode: .realtimePreview,
      cloudSpeechRecognitionEnabled: true,
      refinementMode: .structured,
      refinementEngine: .cloudAI,
      appStyleOverrides: ["com.apple.terminal": .command],
      siteIdentificationAllowed: true,
      siteStyleOverrides: ["mail.example.com": .polite],
      refinementModel: "model-a",
      priceTable: PriceTableSetting(
        currencyCode: "USD", updatedOn: CalendarDay(year: 2026, month: 10, day: 1),
        prices: [try price("model-a", Decimal(string: "0.8")!, 4)]),
      monthlyBudget: MonthlyBudgetSetting(
        limitAmount: Decimal(string: "12.5")!, currencyCode: "USD"),
      modelRetentionMode: .performance,
      performanceRetentionAllowed: true)

    let form = SettingsForm(settings: settings)

    #expect(form.provider == .claude)
    #expect(form.maxRecordingMinutes == "10")
    #expect(form.budgetLimit == "12.5")
    #expect(form.priceRows.map(\.inputPerMillionTokens) == ["0.8"])
    #expect(try form.applied(to: settings) == settings)
  }

  @Test("2.3節, AC-06: 画面で扱わない項目（同意・履歴）は基準の設定の値を残す")
  func unmanagedFieldsAreKept() throws {
    var consent = ConsentState()
    consent.grant(.transmission(.textRefinement(.claude)))
    let base = AppSettings(consentState: consent, historyEnabled: true)

    let saved = try SettingsForm(settings: AppSettings()).applied(to: base)

    #expect(saved.consentState == consent)
    #expect(saved.historyEnabled)
  }

  // MARK: - 録音ショートカット（REC-01）

  @Test("REC-01: 記録したショートカットを保存し、解除すると未設定で保存する")
  func recordingShortcutIsApplied() throws {
    let r = try #require(ShortcutKey(rawValue: "r"))
    let recorded = KeyCombination(key: r, modifiers: [.option, .command])
    var form = SettingsForm(settings: AppSettings())
    form.recordingShortcut = recorded

    let saved = try form.applied(to: AppSettings())
    #expect(saved.recordingShortcut == recorded)

    var cleared = SettingsForm(settings: saved)
    #expect(cleared.recordingShortcut == recorded)
    cleared.recordingShortcut = nil
    #expect(try cleared.applied(to: saved).recordingShortcut == nil)
  }

  @Test(
    "REC-01: 登録できない保存済みのショートカット（修飾キー単独・Fn・修飾キーなし）は保存せず、問題にする",
    arguments: [
      KeyCombination(modifierOnly: .function),
      KeyCombination(modifierOnly: .option),
      KeyCombination(key: .space, modifiers: [.function, .command]),
      KeyCombination(key: .space),
      KeyCombination.escape,
    ])
  func unsupportedRecordingShortcutIsRejected(_ combination: KeyCombination?) {
    let base = AppSettings(recordingShortcut: combination)

    #expect(issues(SettingsForm(settings: base), base: base) == [.recordingShortcut])
  }

  // MARK: - クラウド STT（#188）

  @Test("4章, AC-06, #188: クラウド STT は既定で無効のまま保存し、選んだら保存する。同意は変えない")
  func cloudSpeechRecognitionIsApplied() throws {
    let untouched = try SettingsForm(settings: AppSettings()).applied(to: AppSettings())
    #expect(!untouched.cloudSpeechRecognitionEnabled)

    var form = SettingsForm(settings: AppSettings())
    form.cloudSpeechRecognitionEnabled = true
    let saved = try form.applied(to: AppSettings())
    #expect(saved.cloudSpeechRecognitionEnabled)
    // 選ぶだけでは音声の送信に同意しない（同意は同意の画面で別に行う, AC-06）
    #expect(!saved.consentState.allows(.speechRecognition))

    var cleared = SettingsForm(settings: saved)
    #expect(cleared.cloudSpeechRecognitionEnabled)
    cleared.cloudSpeechRecognitionEnabled = false
    #expect(try cleared.applied(to: saved).cloudSpeechRecognitionEnabled == false)
  }

  // MARK: - Edit Mode のショートカット（AC-14）

  @Test("AC-14: Edit Mode のショートカットは既定で未割り当てのまま保存し、記録・解除を保存する")
  func editModeShortcutIsApplied() throws {
    let untouched = try SettingsForm(settings: AppSettings()).applied(to: AppSettings())
    #expect(untouched.editModeShortcut == nil)

    let e = try #require(ShortcutKey(rawValue: "e"))
    let recorded = KeyCombination(key: e, modifiers: [.option, .command])
    var form = SettingsForm(settings: AppSettings())
    form.editModeShortcut = recorded

    let saved = try form.applied(to: AppSettings())
    #expect(saved.editModeShortcut == recorded)
    #expect(saved.recordingShortcut == nil)

    var cleared = SettingsForm(settings: saved)
    #expect(cleared.editModeShortcut == recorded)
    cleared.editModeShortcut = nil
    #expect(try cleared.applied(to: saved).editModeShortcut == nil)
  }

  @Test("AC-14: 録音ショートカットと同じキーは Edit Mode に割り当てず、問題にする")
  func editModeShortcutSameAsRecordingIsRejected() throws {
    let shortcut = KeyCombination(key: .space, modifiers: [.option, .command])
    var form = SettingsForm(settings: AppSettings())
    form.recordingShortcut = shortcut
    form.editModeShortcut = shortcut

    #expect(issues(form) == [.editModeShortcutSameAsRecording])

    form.editModeShortcut = KeyCombination(key: .space, modifiers: [.control, .command])
    #expect(issues(form).isEmpty)
  }

  @Test(
    "AC-14: 登録できない保存済みの Edit Mode のショートカットは保存せず、問題にする",
    arguments: [
      KeyCombination(modifierOnly: .option),
      KeyCombination(key: .space),
      KeyCombination.escape,
    ])
  func unsupportedEditModeShortcutIsRejected(_ combination: KeyCombination?) {
    let base = AppSettings(editModeShortcut: combination)

    #expect(issues(SettingsForm(settings: base), base: base) == [.editModeShortcut])
  }

  // MARK: - 除外アプリ（7章, AC-12）

  @Test("7章, AC-12: 保存済みの除外アプリを順に一覧にし、そのまま保存すると同じ値になる")
  func excludedAppsRoundTrip() throws {
    let settings = AppSettings(excludedApps: ["com.example.B", "com.example.a"])

    let form = SettingsForm(settings: settings)

    #expect(form.excludedAppRows.map(\.bundleID) == ["com.example.B", "com.example.a"])
    #expect(try form.applied(to: settings).excludedApps == ["com.example.B", "com.example.a"])
  }

  @Test("7章, AC-12: 行を追加して入力した bundle ID を前後の空白を除いて保存し、空の行は保存しない")
  func excludedAppRowsAreSaved() throws {
    var form = SettingsForm(settings: AppSettings())
    form.addExcludedAppRow()
    form.excludedAppRows[0].bundleID = "  com.example.chat "
    form.addExcludedAppRow()

    let saved = try form.applied(to: AppSettings())

    #expect(saved.excludedApps == ["com.example.chat"])
  }

  @Test("7章, AC-12: 削除した行は保存しない")
  func removedExcludedAppIsNotSaved() throws {
    var form = SettingsForm(
      settings: AppSettings(excludedApps: ["com.example.a", "com.example.b"]))
    let id = try #require(form.excludedAppRows.first).id

    form.removeExcludedAppRow(id: id)

    #expect(try form.applied(to: AppSettings()).excludedApps == ["com.example.b"])
  }

  @Test(
    "7章, AC-12: bundle ID の形でない値は行ごとの問題にして、何も保存しない",
    arguments: ["メモ", "com.example app", "com/example", "com.example.アプリ"])
  func invalidExcludedAppIsRejected(bundleID: String) throws {
    var form = SettingsForm(settings: AppSettings())
    form.addExcludedAppRow()
    form.excludedAppRows[0].bundleID = bundleID
    let id = form.excludedAppRows[0].id

    #expect(issues(form) == [.excludedAppBundleID(rowID: id)])
    #expect(SettingsIssue.excludedAppBundleID(rowID: id).rowID == id)
    // 文言に入力値を埋め込まない
    #expect(!SettingsIssue.excludedAppBundleID(rowID: id).message.contains(bundleID))
  }

  @Test("7章, AC-12: 大文字・小文字だけが違う bundle ID は重複として後の行を問題にする")
  func duplicateExcludedAppIsRejected() throws {
    var form = SettingsForm(settings: AppSettings(excludedApps: ["com.example.Chat"]))
    form.addExcludedAppRow()
    form.excludedAppRows[1].bundleID = " COM.EXAMPLE.CHAT"
    let duplicate = form.excludedAppRows[1].id

    #expect(issues(form) == [.excludedAppDuplicate(rowID: duplicate)])
  }

  @Test("7章, AC-12: 起動中のアプリから追加するときは、一覧にあるアプリと bundle ID の形でない値を追加しない")
  func addExcludedAppFromCandidate() throws {
    var form = SettingsForm(settings: AppSettings(excludedApps: ["com.example.chat"]))

    let added = [
      "com.example.mail", "COM.EXAMPLE.CHAT", "not a bundle id", "",
    ].map { form.addExcludedApp(bundleID: $0) }

    #expect(added == [true, false, false, false])

    #expect(
      try form.applied(to: AppSettings()).excludedApps == ["com.example.chat", "com.example.mail"])
  }

  @Test("7章, AC-12: 追加の候補は、通常のアプリのうち自分自身・一覧にあるもの・bundle ID のないものを除き、名前順に並べる")
  func excludedAppCandidates() {
    let form = SettingsForm(settings: AppSettings(excludedApps: ["com.example.Listed"]))
    let running: [ExcludedAppCandidate.RunningApp] = [
      .init(bundleID: "com.example.zeta", name: "Zeta", isRegular: true),
      .init(bundleID: "com.example.listed", name: "Listed", isRegular: true),
      .init(bundleID: "com.example.utter", name: "utter", isRegular: true),
      .init(bundleID: "com.example.agent", name: "Agent", isRegular: false),
      .init(bundleID: nil, name: "No ID", isRegular: true),
      .init(bundleID: "com.example.alpha", name: "Alpha", isRegular: true),
      .init(bundleID: "COM.EXAMPLE.ALPHA", name: "Alpha", isRegular: true),
      .init(bundleID: "com.example.noname", name: nil, isRegular: true),
    ]

    let candidates = ExcludedAppCandidate.candidates(
      from: running, ownBundleID: "com.example.Utter", form: form)

    #expect(
      candidates == [
        ExcludedAppCandidate(bundleID: "com.example.alpha", name: "Alpha"),
        ExcludedAppCandidate(bundleID: "com.example.noname", name: "com.example.noname"),
        ExcludedAppCandidate(bundleID: "com.example.zeta", name: "Zeta"),
      ])
  }

  @Test("2.1節, 2.2節, TXT-01, 6章: 選んだ値を保存する")
  func choicesAreApplied() throws {
    var form = SettingsForm(settings: AppSettings())
    form.recordingTrigger = .pushToTalk
    form.inputMode = .realtimePreview
    form.refinementMode = .raw
    form.modelRetentionMode = .powerSaving
    form.performanceRetentionAllowed = true
    form.maxRecordingMinutes = " 1.5 "
    form.refinementModel = "  model-b "

    let saved = try form.applied(to: AppSettings())

    #expect(saved.recordingTrigger == .pushToTalk)
    #expect(saved.inputMode == .realtimePreview)
    #expect(saved.refinementMode == .raw)
    #expect(saved.modelRetentionMode == .powerSaving)
    #expect(saved.performanceRetentionAllowed)
    #expect(saved.maxRecordingDuration == 90)
    #expect(saved.refinementModel == "model-b")
  }

  // MARK: - 処理系（AC-05）

  @Test("AC-05, #50, #58: Local Basic・Claude・Sign in with ChatGPT・OpenAI API キー方式を選べる")
  func providerChoices() throws {
    #expect(RefinementProviderChoice.localBasic.engine == .localBasic)
    #expect(RefinementProviderChoice.claude.engine == .cloudAI)
    #expect(RefinementProviderChoice.chatGPTSignIn.engine == .cloudAI)
    #expect(RefinementProviderChoice.openAIAPIKey.engine == .cloudAI)

    var form = SettingsForm(settings: AppSettings(refinementEngine: .cloudAI))
    form.provider = .openAIAPIKey
    #expect(issues(form).isEmpty)

    form.provider = .localBasic
    #expect(
      try form.applied(to: AppSettings(refinementEngine: .cloudAI)).refinementEngine == .localBasic)
  }

  @Test("AC-05, #50: Sign in with ChatGPT を選ぶとクラウド AI の送信先を ChatGPT にし、Claude を選ぶと戻す")
  func chatGPTSignInChoiceRoundTrips() throws {
    var form = SettingsForm(settings: AppSettings())
    form.provider = .chatGPTSignIn
    form.chatGPTRefinementModel = "model-x"
    let saved = try form.applied(to: AppSettings())
    #expect(saved.refinementEngine == .cloudAI)
    #expect(saved.cloudRefinementProvider == .chatGPTSignIn)
    #expect(saved.chatGPTRefinementModel == "model-x")
    #expect(SettingsForm(settings: saved).provider == .chatGPTSignIn)

    form.provider = .claude
    let claude = try form.applied(to: saved)
    #expect(claude.cloudRefinementProvider == .claude)
    #expect(SettingsForm(settings: claude).provider == .claude)

    // Local Basic を選んでも送信先は変えない（クラウド AI を選び直すまで送らない）
    form.provider = .localBasic
    let local = try form.applied(to: saved)
    #expect(local.refinementEngine == .localBasic)
    #expect(local.cloudRefinementProvider == .chatGPTSignIn)
    #expect(SettingsForm(settings: local).provider == .localBasic)
  }

  @Test("AC-05, #58: OpenAI API キー方式を選ぶと送信先とモデル名を保存し、Sign in with ChatGPT とは別の選択肢として読み直す")
  func openAIAPIKeyChoiceRoundTrips() throws {
    var form = SettingsForm(settings: AppSettings())
    form.provider = .openAIAPIKey
    form.openAIRefinementModel = " model-y "
    let saved = try form.applied(to: AppSettings())
    #expect(saved.refinementEngine == .cloudAI)
    #expect(saved.cloudRefinementProvider == .openAIAPIKey)
    #expect(saved.openAIRefinementModel == "model-y")
    // Sign in with ChatGPT のモデル名は変えない
    #expect(saved.chatGPTRefinementModel.isEmpty)
    #expect(SettingsForm(settings: saved).provider == .openAIAPIKey)
    #expect(SettingsForm(settings: saved).openAIRefinementModel == "model-y")

    form.provider = .chatGPTSignIn
    let chatGPT = try form.applied(to: saved)
    #expect(chatGPT.cloudRefinementProvider == .chatGPTSignIn)
    // 方式を変えても入力したモデル名は残す
    #expect(chatGPT.openAIRefinementModel == "model-y")

    // Local Basic を選んでも送信先は変えない
    form.provider = .localBasic
    let local = try form.applied(to: saved)
    #expect(local.refinementEngine == .localBasic)
    #expect(local.cloudRefinementProvider == .openAIAPIKey)
  }

  @Test("#58: OpenAI API キー方式でモデル名を入力していなければ、保存はできるが送らないことを知らせる")
  func openAIModelNotEnteredNotice() throws {
    var form = SettingsForm(settings: AppSettings())
    form.provider = .openAIAPIKey
    #expect(form.notices.contains(.openAIModelNotEntered))
    #expect(try form.applied(to: AppSettings()).openAIRefinementModel.isEmpty)
    form.openAIRefinementModel = "model-y"
    #expect(!form.notices.contains(.openAIModelNotEntered))
    form.provider = .chatGPTSignIn
    form.openAIRefinementModel = ""
    #expect(!form.notices.contains(.openAIModelNotEntered))
  }

  @Test("#50: Sign in with ChatGPT でモデルを選んでいなければ、保存はできるが送らないことを知らせる")
  func chatGPTModelNotSelectedNotice() throws {
    var form = SettingsForm(settings: AppSettings())
    form.provider = .chatGPTSignIn
    #expect(form.notices.contains(.chatGPTModelNotSelected))
    #expect(try form.applied(to: AppSettings()).chatGPTRefinementModel.isEmpty)
    form.chatGPTRefinementModel = "model-x"
    #expect(!form.notices.contains(.chatGPTModelNotSelected))
  }

  @Test("AI-03: 既定の処理系は Local Basic")
  func defaultProviderIsLocalBasic() {
    #expect(SettingsForm(settings: AppSettings()).provider == .localBasic)
  }

  // MARK: - 検証

  @Test(
    "REC-05: 最大録音時間は 1〜60 分の半角の数だけを受け付ける",
    arguments: ["0", "0.5", "61", "", "abc", "-5", "1,000", "５", "1e3"])
  func invalidRecordingDuration(text: String) {
    var form = SettingsForm(settings: AppSettings())
    form.maxRecordingMinutes = text
    #expect(issues(form) == [.maxRecordingDuration])
  }

  @Test(
    "REC-05: 範囲の両端と小数の分を受け付け、秒で保存する",
    arguments: [("1", 60.0), ("60", 3600.0), ("2.5", 150.0), (" 5 ", 300.0)])
  func validRecordingDuration(text: String, seconds: Double) throws {
    var form = SettingsForm(settings: AppSettings())
    form.maxRecordingMinutes = text
    #expect(try form.applied(to: AppSettings()).maxRecordingDuration == seconds)
  }

  @Test("REC-05: 秒で保存した値を分で表示し、表示を変えずに保存しても秒の値を変えない")
  func recordingDurationShownInMinutes() throws {
    #expect(SettingsForm(settings: AppSettings()).maxRecordingMinutes == "5")
    let ninety = SettingsForm(settings: AppSettings(maxRecordingDuration: 90))
    #expect(ninety.maxRecordingMinutes == "1.5")

    // 分に割り切れない秒（以前の画面で秒で入れた値）は丸めて表示し、そのまま保存しても丸めない
    let odd = AppSettings(maxRecordingDuration: 100)
    let form = SettingsForm(settings: odd)
    #expect(form.maxRecordingMinutes == "1.67")
    #expect(try form.applied(to: odd).maxRecordingDuration == 100)
    let short = AppSettings(maxRecordingDuration: 30)
    #expect(try SettingsForm(settings: short).applied(to: short).maxRecordingDuration == 30)
  }

  // MARK: - #199 で足した項目

  @Test("REC-01, REC-06, AI-04, 7章: 処理中の押下・Esc・クラウドの切り替え・一時音声の保持期限を保存し、読み直す")
  func issue199ChoicesRoundTrip() throws {
    var form = SettingsForm(settings: AppSettings())
    #expect(form.pressWhileProcessing == .ignore)
    #expect(form.escapeCancelEnabled)
    #expect(!form.cloudRefinementFallbackEnabled)
    #expect(form.temporaryAudioRetentionHours == 24)

    form.pressWhileProcessing = .confirmCancel
    form.escapeCancelEnabled = false
    form.cloudRefinementFallbackEnabled = true
    form.temporaryAudioRetentionHours = 6
    let saved = try form.applied(to: AppSettings())

    #expect(saved.recordingPressWhileProcessing == .confirmCancel)
    #expect(!saved.escapeCancelEnabled)
    #expect(saved.cloudRefinementFallbackEnabled)
    #expect(saved.temporaryAudioRetentionHours == 6)
    // 切り替えを選んでも、同意は変えない（AC-06）
    #expect(saved.consentState == ConsentState())
    #expect(SettingsForm(settings: saved) == form)
  }

  @Test("AI-07: 空の整形用モデル名は保存しない")
  func emptyModelIsRejected() {
    var form = SettingsForm(settings: AppSettings())
    form.refinementModel = "  "
    #expect(issues(form) == [.refinementModelEmpty])
  }

  @Test("AI-04, AI-05: 予算は 0 以上の数と通貨がそろったときだけ保存する")
  func budgetValidation() throws {
    var form = SettingsForm(settings: AppSettings())
    form.budgetEnabled = true
    form.budgetLimit = "abc"
    #expect(Set(issues(form)) == [.budgetLimit, .currencyCode])

    form.budgetLimit = "0"
    form.currencyCode = "usd"
    let saved = try form.applied(to: AppSettings())
    #expect(saved.monthlyBudget == MonthlyBudgetSetting(limitAmount: 0, currencyCode: "USD"))
    #expect(saved.priceTable.currencyCode == "USD")

    form.budgetEnabled = false
    #expect(try form.applied(to: saved).monthlyBudget == nil)
  }

  @Test("AI-05: 形の違う通貨コードは、予算・単価がなくても保存しない", arguments: ["US", "dollar", "U$D"])
  func invalidCurrencyIsRejected(code: String) {
    var form = SettingsForm(settings: AppSettings())
    form.currencyCode = code
    #expect(issues(form) == [.currencyCode])
  }

  @Test("AI-05: 単価があれば通貨と更新日が要る")
  func pricesNeedCurrencyAndDate() {
    var form = SettingsForm(settings: AppSettings())
    form.addPriceRow()
    form.priceRows[0].model = "model-a"
    form.priceRows[0].inputPerMillionTokens = "1"
    form.priceRows[0].outputPerMillionTokens = "2"
    #expect(Set(issues(form)) == [.currencyCode, .priceUpdatedOnMissing])
  }

  @Test("AI-05: 単価の行ごとの問題を行の識別子つきで返し、空の行は無視する")
  func priceRowIssues() throws {
    var form = SettingsForm(settings: AppSettings())
    form.currencyCode = "JPY"
    form.priceUpdatedOn = CalendarDay(year: 2026, month: 10, day: 25)
    for _ in 0..<4 { form.addPriceRow() }
    let ids = form.priceRows.map(\.id)
    form.priceRows[0].model = "model-a"
    form.priceRows[0].inputPerMillionTokens = "1"
    form.priceRows[0].outputPerMillionTokens = "2"
    form.priceRows[1].model = " model-a "
    form.priceRows[1].inputPerMillionTokens = "1"
    form.priceRows[1].outputPerMillionTokens = "-2"
    form.priceRows[2].inputPerMillionTokens = "1"
    form.priceRows[2].outputPerMillionTokens = "1"
    // 4 行目は空のまま

    #expect(
      issues(form) == [
        .priceModelDuplicate(rowID: ids[1]), .priceAmount(rowID: ids[1]),
        .priceModelEmpty(rowID: ids[2]),
      ])

    form.removePriceRow(id: ids[1])
    form.removePriceRow(id: ids[2])
    let saved = try form.applied(to: AppSettings())
    #expect(saved.priceTable.prices.map(\.model) == ["model-a"])
    #expect(saved.priceTable.updatedOn == CalendarDay(year: 2026, month: 10, day: 25))
  }

  @Test("AI-05: 行の識別子は削除・追加しても重ならない")
  func rowIDsAreUnique() {
    var form = SettingsForm(
      settings: AppSettings(appStyleOverrides: ["com.a": .polite, "com.b": .concise]))
    form.removeAppStyleRow(id: form.appStyleRows[0].id)
    form.addAppStyleRow()
    form.addSiteStyleRow()
    form.addPriceRow()
    let ids = form.appStyleRows.map(\.id) + form.siteStyleRows.map(\.id) + form.priceRows.map(\.id)
    #expect(Set(ids).count == ids.count)
  }

  @Test("金額は半角数字と小数点だけを読む", arguments: ["1", "0.25", " 12 "])
  func amountParsing(text: String) {
    #expect(SettingsForm.amount(text) == Decimal(string: text.trimmingCharacters(in: .whitespaces)))
  }

  @Test(
    "金額の桁区切り・符号・指数・全角・途中までの数は読まない",
    arguments: ["1,000", "-1", "+1", "1e2", "１", "1.", ".5", "1.2.3", "12abc"])
  func amountRejects(text: String) {
    #expect(SettingsForm.amount(text) == nil)
  }

  // MARK: - スタイル（CTX-01, CTX-02）

  @Test("CTX-02: アプリ別の上書きは bundle ID を小文字にそろえて保存し、空の行は無視する")
  func appOverridesAreSaved() throws {
    var form = SettingsForm(settings: AppSettings())
    form.addAppStyleRow()
    form.addAppStyleRow()
    form.appStyleRows[0].key = " Com.Apple.Mail "
    form.appStyleRows[0].style = .concise

    let saved = try form.applied(to: AppSettings())

    #expect(saved.appStyleOverrides == ["com.apple.mail": .concise])
    #expect(saved.contextStyleResolver.style(forBundleID: "com.apple.mail") == .concise)
  }

  @Test("CTX-02: 形の違う bundle ID と、大文字・小文字だけ違う重複は保存しない")
  func appOverrideIssues() {
    var form = SettingsForm(settings: AppSettings())
    for _ in 0..<3 { form.addAppStyleRow() }
    let ids = form.appStyleRows.map(\.id)
    form.appStyleRows[0].key = "com.example.app"
    form.appStyleRows[1].key = "COM.EXAMPLE.APP"
    form.appStyleRows[2].key = "com example/app"

    #expect(issues(form) == [.appBundleIDDuplicate(rowID: ids[1]), .appBundleID(rowID: ids[2])])
  }

  @Test("CTX-02: サイト別の上書きは入力した URL・ホスト名から正規化したホスト名で保存する")
  func siteOverridesAreNormalized() throws {
    var form = SettingsForm(settings: AppSettings())
    form.siteIdentificationAllowed = true
    form.addSiteStyleRow()
    form.siteStyleRows[0].key = "https://www.Example.com/inbox?x=1"
    form.siteStyleRows[0].style = .polite

    let saved = try form.applied(to: AppSettings())

    #expect(saved.siteIdentificationAllowed)
    #expect(saved.siteStyleOverrides == ["example.com": .polite])
  }

  @Test("CTX-02: サイト単位の識別は既定で許可せず、許可を外しても上書きの一覧は残す")
  func siteIdentificationIsOptIn() throws {
    let base = AppSettings(
      siteIdentificationAllowed: true, siteStyleOverrides: ["example.com": .polite])
    var form = SettingsForm(settings: base)
    #expect(!SettingsForm(settings: AppSettings()).siteIdentificationAllowed)

    form.siteIdentificationAllowed = false
    let saved = try form.applied(to: base)

    #expect(!saved.siteIdentificationAllowed)
    #expect(saved.siteStyleOverrides == ["example.com": .polite])
    #expect(!saved.contextStyleResolver.site.needsSiteHost)
  }

  @Test("CTX-02: 正規化を重ねると同じになるサイトも重複として扱い、行を黙って消さない")
  func repeatedWWWIsDuplicate() {
    var form = SettingsForm(settings: AppSettings())
    form.addSiteStyleRow()
    form.addSiteStyleRow()
    let ids = form.siteStyleRows.map(\.id)
    form.siteStyleRows[0].key = "example.com"
    form.siteStyleRows[1].key = "www.www.example.com"

    #expect(issues(form) == [.siteHostDuplicate(rowID: ids[1])])
  }

  @Test("CTX-02: 読めないサイトと、正規化すると同じになる重複は保存しない")
  func siteOverrideIssues() {
    var form = SettingsForm(settings: AppSettings())
    for _ in 0..<3 { form.addSiteStyleRow() }
    let ids = form.siteStyleRows.map(\.id)
    form.siteStyleRows[0].key = "example.com"
    form.siteStyleRows[1].key = "https://www.example.com/path"
    form.siteStyleRows[2].key = "user@example.org"

    #expect(issues(form) == [.siteHostDuplicate(rowID: ids[1]), .siteHost(rowID: ids[2])])
  }

  @Test("CTX-03: 問題の文言に利用者の入力値を含めない")
  func issueMessagesDoNotContainInput() {
    var form = SettingsForm(settings: AppSettings())
    form.addSiteStyleRow()
    form.siteStyleRows[0].key = "secret-site.invalid/%%"
    form.addAppStyleRow()
    form.appStyleRows[0].key = "secret app"
    for issue in issues(form) {
      #expect(!issue.message.contains("secret"))
    }
  }

  // MARK: - 案内

  @Test("6章: 高速モードを許可なしで選ぶと、バランスモードとして扱うと案内する")
  func performanceNotice() {
    var form = SettingsForm(settings: AppSettings())
    form.modelRetentionMode = .performance
    #expect(form.notices.contains(.performanceRetentionNotAllowed))
    form.performanceRetentionAllowed = true
    #expect(!form.notices.contains(.performanceRetentionNotAllowed))
  }

  @Test("AI-04, AI-05: Claude を選んだとき、予算の未設定と単価表にないモデルを案内する")
  func costNotices() {
    var form = SettingsForm(settings: AppSettings())
    #expect(form.notices.isEmpty)

    form.provider = .claude
    #expect(form.notices == [.budgetNotSet])

    form.budgetEnabled = true
    #expect(form.notices == [.refinementModelNotInPriceTable])

    form.addPriceRow()
    form.priceRows[0].model = AppSettings.defaultRefinementModel
    #expect(form.notices.isEmpty)
  }

  @Test("AI-04, AI-05, #58: OpenAI API キー方式を選んだとき、予算の未設定と単価表にないモデルを案内する")
  func openAICostNotices() {
    var form = SettingsForm(settings: AppSettings())
    form.provider = .openAIAPIKey
    form.openAIRefinementModel = "model-y"
    #expect(form.notices == [.budgetNotSet])

    form.budgetEnabled = true
    #expect(form.notices == [.refinementModelNotInPriceTable])

    // Claude のモデルの単価では足りない
    form.addPriceRow()
    form.priceRows[0].model = AppSettings.defaultRefinementModel
    #expect(form.notices == [.refinementModelNotInPriceTable])

    form.priceRows[0].model = "model-y"
    #expect(form.notices.isEmpty)
  }

  @Test("AI-05, #50: Sign in with ChatGPT は課金されないため、予算の案内を出さない")
  func chatGPTSignInHasNoCostNotices() {
    var form = SettingsForm(settings: AppSettings())
    form.provider = .chatGPTSignIn
    form.chatGPTRefinementModel = "model-x"
    #expect(form.notices.isEmpty)
  }

  @Test("AI-05: 日付選択の値と更新日を相互に変換できる")
  func calendarDayConversion() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "Asia/Tokyo"))
    let day = try #require(CalendarDay(year: 2026, month: 2, day: 28))
    let date = try #require(SettingsForm.date(of: day, in: calendar))
    #expect(SettingsForm.calendarDay(of: date, in: calendar) == day)
  }
}
