import Foundation
import Testing
import UtterAI
import UtterCore
import UtterPersistence

/// テストごとに専用の suite の UserDefaults を作り、終わったら消す
final class TestDefaults {
  let defaults: UserDefaults
  private let name: String

  init() throws {
    name = "utter-mac-tests-\(UUID().uuidString)"
    defaults = try #require(UserDefaults(suiteName: name))
  }

  deinit {
    defaults.removePersistentDomain(forName: name)
  }
}

@MainActor
struct SettingsModelTests {
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

  private func makeModel() -> SettingsModel {
    let usageStore = self.usageStore
    let now = self.now
    return SettingsModel(
      store: store, openUsageStore: { usageStore }, now: { now }, calendar: calendar)
  }

  private func costSettings(limit: Decimal = 10) throws -> AppSettings {
    AppSettings(
      refinementEngine: .cloudAI,
      priceTable: PriceTableSetting(
        currencyCode: "USD", updatedOn: CalendarDay(year: 2026, month: 10, day: 1),
        prices: [
          try #require(
            ModelPriceSetting(
              model: AppSettings.defaultRefinementModel, inputPerMillionTokens: 1,
              outputPerMillionTokens: 5))
        ]),
      monthlyBudget: MonthlyBudgetSetting(limitAmount: limit, currencyCode: "USD"))
  }

  @Test("2.3節: 保存した値を版 2 の設定として保存し、開き直しても同じ値を読む")
  func savedValuesSurviveReload() throws {
    let model = makeModel()
    model.form.recordingTrigger = .pushToTalk
    model.form.siteIdentificationAllowed = true
    model.form.addSiteStyleRow()
    model.form.siteStyleRows[0].key = "example.com"
    model.form.siteStyleRows[0].style = .technical

    #expect(model.save())
    #expect(model.issues.isEmpty)

    let loaded = store.load()
    #expect(loaded.version == 2)
    #expect(loaded.recordingTrigger == .pushToTalk)
    #expect(loaded.siteStyleOverrides == ["example.com": .technical])
    #expect(makeModel().form == model.form)
  }

  @Test("2.3節: 問題があれば何も保存せず、問題を返す")
  func invalidInputIsNotSaved() {
    let model = makeModel()
    model.form.recordingTrigger = .pushToTalk
    model.form.maxRecordingMinutes = "0"

    #expect(!model.save())
    #expect(model.issues == [.maxRecordingDuration])
    #expect(store.load() == AppSettings())

    model.revert()
    #expect(model.issues.isEmpty)
    #expect(model.form == SettingsForm(settings: AppSettings()))
  }

  @Test("AC-06: 保存は保存先の最新の値を基準にし、ほかの画面で変えた同意を上書きしない")
  func saveKeepsConsentChangedElsewhere() throws {
    let model = makeModel()
    var consent = ConsentState()
    consent.grant(.transmission(.textRefinement(.claude)))
    try store.save(AppSettings(consentState: consent))

    model.form.inputMode = .realtimePreview
    #expect(model.save())

    let loaded = store.load()
    #expect(loaded.consentState.allows(.textRefinement(.claude)))
    #expect(loaded.inputMode == .realtimePreview)
  }

  @Test("2.3節: 読み直すと、ほかの経路で保存された値を画面に反映する")
  func reloadPicksUpExternalChanges() throws {
    let model = makeModel()
    try store.save(AppSettings(refinementMode: .raw))
    model.reload()
    #expect(model.form.refinementMode == .raw)
  }

  @Test("AI-05: 今月の推定費用の累計・予算・残り・単価表の更新日を表示する")
  func costSummaryShowsCurrentMonth() async throws {
    try store.save(try costSettings(limit: 10))
    try usageStore.record(
      Decimal(string: "2.5")!, currencyCode: "USD", in: UsageMonth(year: 2026, month: 10))
    // 前月の累計と、前月の別の通貨の記録は今月の累計に含めない
    try usageStore.record(7, currencyCode: "USD", in: UsageMonth(year: 2026, month: 9))
    try usageStore.record(100, currencyCode: "JPY", in: UsageMonth(year: 2026, month: 9))
    let model = makeModel()

    await model.refreshCost()

    guard case .summary(let summary) = model.cost else {
      Issue.record("推定費用を表示していない: \(model.cost)")
      return
    }
    #expect(summary.month == (try YearMonth(year: 2026, month: 10)))
    #expect(summary.currency.code == "USD")
    #expect(summary.estimatedSpent == Decimal(string: "2.5")!)
    #expect(summary.reserved == 0)
    #expect(summary.limitAmount == 10)
    #expect(summary.estimatedRemaining == Decimal(string: "7.5")!)
    #expect(summary.priceTableUpdatedOn == (try CivilDate(year: 2026, month: 10, day: 1)))
  }

  @Test("AI-05: 累計が予算を超えても、推定の残りは 0 と表示する")
  func remainingIsNotNegative() async throws {
    try store.save(try costSettings(limit: 1))
    try usageStore.record(3, currencyCode: "USD", in: UsageMonth(year: 2026, month: 10))
    let model = makeModel()

    await model.refreshCost()

    guard case .summary(let summary) = model.cost else {
      Issue.record("推定費用を表示していない")
      return
    }
    #expect(summary.estimatedSpent == 3)
    #expect(summary.estimatedRemaining == 0)
  }

  @Test("AI-05: 予算・単価表の通貨と更新日がそろわなければ、推定費用を 0 として表示しない")
  func costUnavailableReasons() async throws {
    let model = makeModel()
    await model.refreshCost()
    #expect(model.cost == .unavailable(.budgetNotSet))

    try store.save(
      AppSettings(monthlyBudget: MonthlyBudgetSetting(limitAmount: 1, currencyCode: "USD")))
    model.reload()
    await model.refreshCost()
    #expect(model.cost == .unavailable(.priceTableIncomplete))

    try store.save(
      AppSettings(
        priceTable: PriceTableSetting(
          currencyCode: "JPY", updatedOn: CalendarDay(year: 2026, month: 1, day: 1)),
        monthlyBudget: MonthlyBudgetSetting(limitAmount: 1, currencyCode: "USD")))
    model.reload()
    await model.refreshCost()
    #expect(model.cost == .unavailable(.currencyMismatch))
  }

  @Test("AI-04, AI-05: 今月に別の通貨の記録があれば、0 から数え直して表示しない")
  func usageInOtherCurrencyIsNotShownAsZero() async throws {
    try store.save(try costSettings())
    try usageStore.record(500, currencyCode: "JPY", in: UsageMonth(year: 2026, month: 10))
    let model = makeModel()

    await model.refreshCost()

    #expect(model.cost == .unavailable(.usageInOtherCurrency))
  }

  @Test("AI-05: 累計を読めなければ、読めないと表示する")
  func unreadableUsage() async throws {
    try store.save(try costSettings())
    struct OpenFailure: Error {}
    let now = self.now
    let model = SettingsModel(
      store: store, openUsageStore: { throw OpenFailure() }, now: { now }, calendar: calendar)

    await model.refreshCost()

    #expect(model.cost == .unreadable)
  }

  @Test("AI-05: 保存した予算を推定費用の表示に使う")
  func savedBudgetIsUsedForCost() async throws {
    let model = makeModel()
    model.form.budgetEnabled = true
    model.form.budgetLimit = "20"
    model.form.currencyCode = "usd"
    model.form.priceUpdatedOn = CalendarDay(year: 2026, month: 10, day: 20)
    #expect(model.save())

    await model.refreshCost()

    guard case .summary(let summary) = model.cost else {
      Issue.record("推定費用を表示していない")
      return
    }
    #expect(summary.limitAmount == 20)
    #expect(summary.estimatedSpent == 0)
  }
}
