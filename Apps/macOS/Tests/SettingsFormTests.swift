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

  @Test("AC-05, AI-05, CTX-02, REC-05: 保存済みの値から作った入力欄をそのまま保存すると同じ設定になる")
  func formRoundTripsSettings() throws {
    let settings = AppSettings(
      maxRecordingDuration: 600,
      recordingTrigger: .pushToTalk,
      inputMode: .realtimePreview,
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
    #expect(form.maxRecordingSeconds == "600")
    #expect(form.budgetLimit == "12.5")
    #expect(form.priceRows.map(\.inputPerMillionTokens) == ["0.8"])
    #expect(try form.applied(to: settings) == settings)
  }

  @Test("2.3節, AC-06: 画面で扱わない項目（同意・履歴・除外アプリ・ショートカット）は基準の設定の値を残す")
  func unmanagedFieldsAreKept() throws {
    var consent = ConsentState()
    consent.grant(.transmission(.textRefinement(.claude)))
    let base = AppSettings(
      recordingShortcut: KeyCombination(key: .space, modifiers: [.option]),
      consentState: consent, historyEnabled: true, excludedApps: ["com.example.secret"])

    let saved = try SettingsForm(settings: AppSettings()).applied(to: base)

    #expect(saved.consentState == consent)
    #expect(saved.historyEnabled)
    #expect(saved.excludedApps == ["com.example.secret"])
    #expect(saved.recordingShortcut == base.recordingShortcut)
  }

  @Test("2.1節, 2.2節, TXT-01, 6章: 選んだ値を保存する")
  func choicesAreApplied() throws {
    var form = SettingsForm(settings: AppSettings())
    form.recordingTrigger = .pushToTalk
    form.inputMode = .realtimePreview
    form.refinementMode = .raw
    form.modelRetentionMode = .powerSaving
    form.performanceRetentionAllowed = true
    form.maxRecordingSeconds = " 90 "
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

  @Test("AC-05: Local Basic と Claude は選べ、ChatGPT は判定待ちで選べない")
  func providerChoices() throws {
    #expect(RefinementProviderChoice.localBasic.engine == .localBasic)
    #expect(RefinementProviderChoice.claude.engine == .cloudAI)
    #expect(!RefinementProviderChoice.chatGPT.isSelectable)

    var form = SettingsForm(settings: AppSettings(refinementEngine: .cloudAI))
    form.provider = .chatGPT
    #expect(issues(form) == [.providerUnavailable])

    form.provider = .localBasic
    #expect(
      try form.applied(to: AppSettings(refinementEngine: .cloudAI)).refinementEngine == .localBasic)
  }

  @Test("AI-03: 既定の処理系は Local Basic")
  func defaultProviderIsLocalBasic() {
    #expect(SettingsForm(settings: AppSettings()).provider == .localBasic)
  }

  // MARK: - 検証

  @Test(
    "REC-05: 最大録音時間は 1〜3600 秒の半角の数だけを受け付ける",
    arguments: ["0", "3601", "", "abc", "-5", "1,000", "５", "1e3"])
  func invalidRecordingDuration(text: String) {
    var form = SettingsForm(settings: AppSettings())
    form.maxRecordingSeconds = text
    #expect(issues(form) == [.maxRecordingDuration])
  }

  @Test("REC-05: 範囲の両端は受け付ける", arguments: ["1", "3600", "45.5"])
  func validRecordingDuration(text: String) throws {
    var form = SettingsForm(settings: AppSettings())
    form.maxRecordingSeconds = text
    #expect(try form.applied(to: AppSettings()).maxRecordingDuration == Double(text))
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

  @Test("AI-05: 日付選択の値と更新日を相互に変換できる")
  func calendarDayConversion() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "Asia/Tokyo"))
    let day = try #require(CalendarDay(year: 2026, month: 2, day: 28))
    let date = try #require(SettingsForm.date(of: day, in: calendar))
    #expect(SettingsForm.calendarDay(of: date, in: calendar) == day)
  }
}
