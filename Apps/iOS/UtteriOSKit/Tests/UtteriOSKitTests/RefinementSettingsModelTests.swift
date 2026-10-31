import Foundation
import Testing
import UtterAI
import UtterCore
import UtterPersistence

@testable import UtteriOSKit

/// iOS の整形・予算の設定画面の保存・読み込み・検証と、今月の推定費用の表示（AI-03, AI-04, AI-05, iOS-10）。
@MainActor
struct RefinementSettingsModelTests {
  private let temporaryDefaults: TemporaryDefaults
  private let usageStore: MonthlyUsageStore
  /// 2027-01-15 00:00:00 UTC
  private let date = Date(timeIntervalSince1970: 1_800_000_000)
  private let model = AppSettings.defaultRefinementModel

  init() throws {
    temporaryDefaults = try TemporaryDefaults()
    usageStore = MonthlyUsageStore(database: try UtterDatabase.inMemory())
  }

  private var store: AppSettingsStore { AppSettingsStore(defaults: temporaryDefaults.defaults) }

  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    return calendar
  }

  private func settingsModel(
    openUsageStore: (@Sendable () throws -> MonthlyUsageStore)? = nil
  ) -> RefinementSettingsModel {
    let usageStore = self.usageStore
    let date = self.date
    return RefinementSettingsModel(
      store: store, openUsageStore: openUsageStore ?? { usageStore }, now: { date },
      calendar: calendar)
  }

  /// Claude・月次予算・既定のモデルの単価を入力する
  private func fillCloudSettings(_ settingsModel: RefinementSettingsModel, limit: String = "10") {
    settingsModel.form.provider = .claude
    settingsModel.form.budgetEnabled = true
    settingsModel.form.budgetLimit = limit
    settingsModel.form.currencyCode = "usd"
    settingsModel.form.priceUpdatedOn = CalendarDay(year: 2026, month: 10, day: 1)
    settingsModel.form.addPriceRow()
    let id = settingsModel.form.priceRows[0].id
    settingsModel.form.priceRows[0] = RefinementSettingsForm.PriceRow(
      id: id, model: model, inputPerMillionTokens: "3", outputPerMillionTokens: "15")
  }

  @Test("AI-03: 既定は Local Basic で、予算・単価表は未設定")
  func defaultsToLocalBasic() {
    let settingsModel = settingsModel()

    #expect(settingsModel.form.provider == .localBasic)
    #expect(settingsModel.form.refinementModel == model)
    #expect(!settingsModel.form.budgetEnabled)
    #expect(settingsModel.form.priceRows.isEmpty)
    #expect(settingsModel.form.notices.isEmpty)
  }

  @Test("AI-03, AI-04: Claude・月次予算・単価表を保存し、クラウド整形と同じ保存先から読める")
  func savesProviderBudgetAndPriceTable() throws {
    let settingsModel = settingsModel()
    fillCloudSettings(settingsModel, limit: "12.5")

    #expect(settingsModel.save())

    let saved = store.load()
    #expect(saved.refinementEngine == .cloudAI)
    #expect(saved.monthlyBudget == MonthlyBudgetSetting(limitAmount: 12.5, currencyCode: "USD"))
    #expect(saved.priceTable.currencyCode == "USD")
    #expect(saved.priceTable.updatedOn == CalendarDay(year: 2026, month: 10, day: 1))
    let price = try #require(saved.priceTable.price(for: model))
    #expect(price.inputPerMillionTokens == 3)
    #expect(price.outputPerMillionTokens == 15)
    #expect(settingsModel.issues.isEmpty)
    #expect(!settingsModel.saveFailed)
    // 予算の判定（`UsageStoreBudgetSource`）が使える単価表になっている
    #expect(UsageStoreBudgetSource.priceTable(from: saved.priceTable) != nil)
  }

  @Test("保存済みの値を読み込み、入力欄に戻す")
  func loadsSavedValues() throws {
    var settings = AppSettings()
    settings.refinementEngine = .cloudAI
    settings.monthlyBudget = MonthlyBudgetSetting(limitAmount: 1500, currencyCode: "JPY")
    settings.priceTable = PriceTableSetting(
      currencyCode: "JPY", updatedOn: CalendarDay(year: 2026, month: 9, day: 30),
      prices: [
        try #require(
          ModelPriceSetting(model: model, inputPerMillionTokens: 450, outputPerMillionTokens: 0.5))
      ])
    try store.save(settings)

    let settingsModel = settingsModel()

    #expect(settingsModel.form.provider == .claude)
    #expect(settingsModel.form.budgetEnabled)
    #expect(settingsModel.form.budgetLimit == "1500")
    #expect(settingsModel.form.currencyCode == "JPY")
    #expect(settingsModel.form.priceUpdatedOn == CalendarDay(year: 2026, month: 9, day: 30))
    #expect(settingsModel.form.priceRows.map(\.model) == [model])
    #expect(settingsModel.form.priceRows.map(\.outputPerMillionTokens) == ["0.5"])
  }

  @Test(
    "AI-04: 負・桁区切り・全角・空の予算は保存しない",
    arguments: ["-1", "1,000", "１０", "", "abc", "1e3"])
  func rejectsInvalidBudget(limit: String) {
    let settingsModel = settingsModel()
    fillCloudSettings(settingsModel, limit: limit)

    #expect(!settingsModel.save())

    #expect(settingsModel.issues == [.budgetLimit])
    // 一部だけを保存しない（処理系も Local Basic のまま）
    #expect(store.load() == AppSettings())
  }

  @Test("AI-04: 上限 0 は「費用をかけない」設定として保存できる")
  func acceptsZeroBudget() {
    let settingsModel = settingsModel()
    fillCloudSettings(settingsModel, limit: "0")

    #expect(settingsModel.save())

    #expect(store.load().monthlyBudget?.limitAmount == 0)
  }

  @Test("通貨・単価・モデル名・更新日の問題を項目と行ごとに返す")
  func reportsIssuesPerField() {
    let settingsModel = settingsModel()
    fillCloudSettings(settingsModel)
    settingsModel.form.currencyCode = "US"
    settingsModel.form.refinementModel = "  "
    settingsModel.form.priceUpdatedOn = nil
    settingsModel.form.addPriceRow()
    let second = settingsModel.form.priceRows[1].id
    settingsModel.form.priceRows[1].model = model
    settingsModel.form.priceRows[1].inputPerMillionTokens = "-3"
    settingsModel.form.priceRows[1].outputPerMillionTokens = "15"

    #expect(!settingsModel.save())

    #expect(
      Set(settingsModel.issues)
        == [
          .refinementModelEmpty, .currencyCode, .priceUpdatedOnMissing,
          .priceModelDuplicate(rowID: second), .priceAmount(rowID: second),
        ])
    #expect(
      settingsModel.issues(forRow: second) == [
        .priceModelDuplicate(rowID: second), .priceAmount(rowID: second),
      ])
    #expect(store.load() == AppSettings())
  }

  @Test("入力しなかった単価の行は保存しない")
  func ignoresBlankPriceRows() {
    let settingsModel = settingsModel()
    fillCloudSettings(settingsModel)
    settingsModel.form.addPriceRow()

    #expect(settingsModel.save())

    #expect(store.load().priceTable.prices.count == 1)
    #expect(settingsModel.form.priceRows.count == 1)
  }

  @Test("AC-06: 保存は同意状態をほかの画面の変更ごと残す")
  func savingKeepsConsent() throws {
    let settingsModel = settingsModel()
    // 画面を開いた後に同意の画面で同意した
    try ConsentSettingsController(store: store).setGranted(
      true, for: CloudFixtures.claudeConsent)
    fillCloudSettings(settingsModel)

    #expect(settingsModel.save())

    #expect(store.load().consentState.allows(.textRefinement(.claude)))
  }

  @Test("AI-03: Local Basic に戻すと、予算・単価表を残したまま処理系だけを戻す")
  func switchingBackToLocalKeepsBudget() {
    let settingsModel = settingsModel()
    fillCloudSettings(settingsModel)
    #expect(settingsModel.save())

    settingsModel.form.provider = .localBasic
    #expect(settingsModel.save())

    let saved = store.load()
    #expect(saved.refinementEngine == .localBasic)
    #expect(saved.monthlyBudget != nil)
  }

  @Test("予算を無効にすると保存済みの予算を消す")
  func disablingBudgetRemovesIt() {
    let settingsModel = settingsModel()
    fillCloudSettings(settingsModel)
    #expect(settingsModel.save())

    settingsModel.form.budgetEnabled = false
    settingsModel.form.budgetLimit = "-1"
    #expect(settingsModel.save())

    #expect(store.load().monthlyBudget == nil)
  }

  @Test("AI-04: 通貨・単価表・推定費用は月次予算を使うときだけ出し、オフにしても入力済みの値は残す")
  func budgetDetailsFollowBudgetToggle() {
    let settingsModel = settingsModel()
    #expect(!settingsModel.showsBudgetDetails)

    fillCloudSettings(settingsModel)
    #expect(settingsModel.showsBudgetDetails)
    #expect(settingsModel.save())

    settingsModel.form.budgetEnabled = false
    #expect(!settingsModel.showsBudgetDetails)
    #expect(settingsModel.save())

    #expect(!settingsModel.showsBudgetDetails)
    #expect(settingsModel.form.currencyCode == "USD")
    #expect(settingsModel.form.priceRows.count == 1)
    #expect(store.load().priceTable.price(for: model) != nil)
  }

  @Test("予算がオフでも、通貨・単価表に問題があって保存できないときは直せるよう出す")
  func budgetDetailsShownWhenTheyBlockSaving() {
    let settingsModel = settingsModel()
    fillCloudSettings(settingsModel)
    settingsModel.form.budgetEnabled = false
    settingsModel.form.priceUpdatedOn = nil

    #expect(!settingsModel.save())

    #expect(settingsModel.issues == [.priceUpdatedOnMissing])
    #expect(settingsModel.showsBudgetDetails)
  }

  @Test("元に戻すと、編集中の値と問題を捨てて保存済みの値に戻す")
  func revertRestoresSavedValues() {
    let settingsModel = settingsModel()
    fillCloudSettings(settingsModel, limit: "-1")
    #expect(!settingsModel.save())

    settingsModel.revert()

    #expect(settingsModel.form == RefinementSettingsForm(settings: AppSettings()))
    #expect(settingsModel.issues.isEmpty)
  }

  @Test("読み直すと、ほかの経路で保存された値を反映する")
  func reloadReflectsLatestSettings() throws {
    let settingsModel = settingsModel()
    var settings = store.load()
    settings.refinementEngine = .cloudAI
    try store.save(settings)

    settingsModel.reload()

    #expect(settingsModel.form.provider == .claude)
  }

  @Test("AI-04, AI-05: Claude を選んで予算・単価がそろわなければ案内する")
  func noticesWhenCloudIsNotReady() {
    var form = RefinementSettingsForm(settings: AppSettings())
    form.provider = .claude
    #expect(form.notices == [.budgetNotSet])

    form.budgetEnabled = true
    #expect(form.notices == [.priceUpdatedOnNotSet, .refinementModelNotInPriceTable])

    form.provider = .localBasic
    #expect(form.notices.isEmpty)
  }

  @Test("AI-05: 保存した予算の通貨の今月の累計から推定費用を表示する")
  func showsEstimatedCostOfThisMonth() async throws {
    try usageStore.record(2.5, currencyCode: "USD", in: UsageMonth(year: 2027, month: 1))
    // 先月と別の通貨の記録は含めない
    try usageStore.record(9, currencyCode: "USD", in: UsageMonth(year: 2026, month: 12))
    try usageStore.record(100, currencyCode: "JPY", in: UsageMonth(year: 2027, month: 1))
    let settingsModel = settingsModel()
    fillCloudSettings(settingsModel)
    #expect(settingsModel.save())

    await settingsModel.refreshCost()

    guard case .summary(let summary) = settingsModel.cost else {
      Issue.record("推定費用を表示できなかった: \(settingsModel.cost)")
      return
    }
    let january = try YearMonth(year: 2027, month: 1)
    #expect(summary.month == january)
    #expect(summary.currency.code == "USD")
    #expect(summary.estimatedSpent == 2.5)
    #expect(summary.limitAmount == 10)
    #expect(summary.estimatedRemaining == 7.5)
  }

  @Test("AI-05: 推定費用は編集中ではなく保存済みの値で作る")
  func estimatedCostUsesSavedSettings() async {
    let settingsModel = settingsModel()
    fillCloudSettings(settingsModel)

    await settingsModel.refreshCost()

    #expect(settingsModel.cost == .unavailable(.budgetNotSet))
  }

  @Test("AI-05: 単価表の通貨か更新日がなければ推定費用を表示しない")
  func estimatedCostNeedsPriceTable() async {
    let settingsModel = settingsModel()
    fillCloudSettings(settingsModel)
    settingsModel.form.priceRows = []
    settingsModel.form.priceUpdatedOn = nil
    #expect(settingsModel.save())

    await settingsModel.refreshCost()

    #expect(settingsModel.cost == .unavailable(.priceTableIncomplete))
  }

  @Test("AI-05: 予算と単価表の通貨が異なれば推定費用を表示しない")
  func estimatedCostNeedsSameCurrency() async throws {
    var settings = AppSettings()
    settings.monthlyBudget = MonthlyBudgetSetting(limitAmount: 10, currencyCode: "USD")
    settings.priceTable = PriceTableSetting(
      currencyCode: "JPY", updatedOn: CalendarDay(year: 2026, month: 10, day: 1))
    try store.save(settings)
    let settingsModel = settingsModel()

    await settingsModel.refreshCost()

    #expect(settingsModel.cost == .unavailable(.currencyMismatch))
  }

  @Test("AI-05: 累計の保存先を開けなければ読めないと表示する")
  func estimatedCostUnreadable() async {
    struct OpenFailure: Error {}
    let settingsModel = settingsModel(openUsageStore: { throw OpenFailure() })
    fillCloudSettings(settingsModel)
    #expect(settingsModel.save())

    await settingsModel.refreshCost()

    #expect(settingsModel.cost == .unreadable)
  }
}
