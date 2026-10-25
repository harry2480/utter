import Foundation
import Testing
import UtterAI
import UtterCore
import UtterPersistence

@testable import UtteriOSKit

/// 設定の月次予算・単価表と保存した累計で予算を確かめ、送信後の推定費用を保存する（AI-04, AI-05）。
struct UsageStoreBudgetSourceTests {
  private let directory = TemporaryDirectory()
  private let request = RefinementRequest(text: "えーと明日の会議は10時からです", mode: .natural)
  /// 2027-01-15 00:00:00 UTC
  private let date = Date(timeIntervalSince1970: 1_800_000_000)
  private let usage = TokenUsage(inputTokens: 100_000, outputTokens: 10_000)
  private let model = AppSettings.defaultRefinementModel
  private let maxOutputTokens = 1024

  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    return calendar
  }

  private var pendingURL: URL { directory.url.appending(path: "pending.json") }

  private func usageMonth() throws -> UsageMonth { try UsageMonth(year: 2027, month: 1) }

  /// 月次予算と、既定のモデルの単価（入力 3 USD・出力 15 USD / 100万トークン）を設定した設定
  private func configuredSettings(limit: Decimal = 10) throws -> AppSettings {
    AppSettings(
      priceTable: PriceTableSetting(
        currencyCode: "USD", updatedOn: CalendarDay(year: 2026, month: 10, day: 1),
        prices: [
          try #require(
            ModelPriceSetting(
              model: model, inputPerMillionTokens: 3, outputPerMillionTokens: 15))
        ]),
      monthlyBudget: MonthlyBudgetSetting(limitAmount: limit, currencyCode: "USD"))
  }

  /// 見込みの使用量の推定費用
  private func expectedCost() throws -> Decimal {
    let usage = UsageStoreBudgetSource.expectedUsage(
      for: request, maxOutputTokens: maxOutputTokens)
    return try CostEstimator(priceTable: CloudFixtures.priceTable).estimate(
      model: model, usage: usage
    ).amount
  }

  private func source(_ store: MonthlyUsageStore) -> UsageStoreBudgetSource {
    UsageStoreBudgetSource(
      makeStore: { store }, pendingReservationURL: pendingURL, calendar: calendar)
  }

  private func begin(
    _ source: UsageStoreBudgetSource, settings: AppSettings
  ) async -> CloudRefinementBudgetResult {
    await source.begin(
      model: model, maxOutputTokens: maxOutputTokens, request: request, settings: settings,
      at: date)
  }

  private func ready(
    _ source: UsageStoreBudgetSource, settings: AppSettings
  ) async throws -> CloudRefinementBudget {
    guard case .ready(let budget) = await begin(source, settings: settings) else {
      Issue.record("予算を用意できなかった")
      throw CancellationError()
    }
    return budget
  }

  private func reason(
    _ source: UsageStoreBudgetSource, settings: AppSettings
  ) async -> CloudBudgetUnavailableReason? {
    guard case .unavailable(let reason) = await begin(source, settings: settings) else {
      return nil
    }
    return reason
  }

  private func refine(
    with budget: CloudRefinementBudget, provider: StubAIProvider
  ) async throws -> RefinementOutcome {
    var consent = ConsentState()
    consent.grant(CloudFixtures.claudeConsent)
    let outcome = try await RefinementRouter(provider: provider, localRefiner: LocalBasicRefiner())
      .refine(request, consent: consent, budget: budget.budget, sensitivity: { .allowedInput })
    await budget.finish()
    return outcome
  }

  @Test("AI-04: 月次予算・単価表が未設定、通貨の不一致、単価表にないモデルは理由を分けて送信しない")
  func unavailableReasons() async throws {
    let store = MonthlyUsageStore(database: try .inMemory())
    let configured = try configuredSettings()

    #expect(await reason(source(store), settings: AppSettings()) == .notConfigured)
    var noBudget = configured
    noBudget.monthlyBudget = nil
    #expect(await reason(source(store), settings: noBudget) == .notConfigured)
    var noDate = configured
    noDate.priceTable = PriceTableSetting(
      currencyCode: "USD", updatedOn: nil, prices: configured.priceTable.prices)
    #expect(await reason(source(store), settings: noDate) == .notConfigured)
    var otherCurrency = configured
    otherCurrency.monthlyBudget = MonthlyBudgetSetting(limitAmount: 10, currencyCode: "JPY")
    #expect(await reason(source(store), settings: otherCurrency) == .currencyMismatch)
    var otherModel = configured
    otherModel.priceTable = PriceTableSetting(
      currencyCode: "USD", updatedOn: CalendarDay(year: 2026, month: 10, day: 1),
      prices: [
        try #require(
          ModelPriceSetting(
            model: "other-model", inputPerMillionTokens: 1, outputPerMillionTokens: 1))
      ])
    #expect(await reason(source(store), settings: otherModel) == .modelNotPriced)
  }

  @Test("AI-05: 送信後の推定費用を今月の累計に加算して保存し、未確定の予約を消す")
  func recordsEstimatedCost() async throws {
    let store = MonthlyUsageStore(database: try .inMemory())
    let budget = try await ready(source(store), settings: try configuredSettings())
    #expect(FileManager.default.fileExists(atPath: pendingURL.path))

    let outcome = try await refine(
      with: budget,
      provider: StubAIProvider(behavior: .respond("明日の会議は10時からです。", usage: usage)))

    #expect(outcome.source == .cloud)
    // 100,000 × 3 / 1,000,000 + 10,000 × 15 / 1,000,000 = 0.45
    #expect(try store.spent(in: usageMonth(), currencyCode: "USD") == Decimal(string: "0.45"))
    #expect(!FileManager.default.fileExists(atPath: pendingURL.path))
  }

  @Test("AI-05: 同じ整形の記録を2回呼んでも1回だけ加算する")
  func finishTwiceRecordsOnce() async throws {
    let store = MonthlyUsageStore(database: try .inMemory())
    let budget = try await ready(source(store), settings: try configuredSettings())

    _ = try await refine(
      with: budget,
      provider: StubAIProvider(behavior: .respond("明日の会議は10時からです。", usage: usage)))
    await budget.finish()

    #expect(try store.spent(in: usageMonth(), currencyCode: "USD") == Decimal(string: "0.45"))
  }

  @Test("AI-04, AI-05: 送信後にキャンセルしても見込み費用を累計に加算し、次の整形の予算を用意できる")
  func cancelAfterSendingRecordsExpectedCost() async throws {
    let store = MonthlyUsageStore(database: try .inMemory())
    let source = source(store)
    let settings = try configuredSettings()
    let budget = try await ready(source, settings: settings)
    let provider = StubAIProvider(behavior: .respond("明日の会議は10時からです。"), delay: .seconds(3600))
    let request = request

    let task = Task {
      var consent = ConsentState()
      consent.grant(CloudFixtures.claudeConsent)
      let outcome = try? await RefinementRouter(
        provider: provider, localRefiner: LocalBasicRefiner()
      ).refine(request, consent: consent, budget: budget.budget, sensitivity: { .allowedInput })
      await budget.finish()
      return outcome
    }
    let sent = await waitUntilAsync { await provider.callCount == 1 }
    #expect(sent)
    task.cancel()
    // キャンセルされたセッションの結果は返らない
    #expect(await task.value == nil)

    #expect(try store.spent(in: usageMonth(), currencyCode: "USD") == expectedCost())
    guard case .ready = await begin(source, settings: settings) else {
      Issue.record("次の整形の予算を用意できなかった")
      return
    }
  }

  @Test("AI-04: 送信中にアプリが終了して残った予約は、次の整形の前に見込み費用で累計に加算する")
  func recoversPendingReservationAfterTermination() async throws {
    let store = MonthlyUsageStore(database: try .inMemory())
    let settings = try configuredSettings()
    // 記録せずに終了した（finish を呼ばない）
    _ = try await ready(source(store), settings: settings)

    let relaunched = source(store)
    _ = try await ready(relaunched, settings: settings)

    #expect(try store.spent(in: usageMonth(), currencyCode: "USD") == expectedCost())
  }

  @Test("AI-04: 保存した今月の累計で上限に達していれば、送信せずに退避する")
  func spentBudgetBlocksSending() async throws {
    let store = MonthlyUsageStore(database: try .inMemory())
    try store.record(10, currencyCode: "USD", in: usageMonth())
    let provider = StubAIProvider(behavior: .respond("明日の会議は10時からです。", usage: usage))
    let budget = try await ready(source(store), settings: try configuredSettings())

    let outcome = try await refine(with: budget, provider: provider)

    #expect(outcome.source == .localFallback(.providerFailed(.budgetExceeded)))
    #expect(await provider.callCount == 0)
    #expect(try store.spent(in: usageMonth(), currencyCode: "USD") == 10)
    #expect(!FileManager.default.fileExists(atPath: pendingURL.path))
  }

  @Test("AI-04: 前の整形の記録が終わるまでは次の予算を用意せず、終われば用意する")
  func secondBeginWaitsForFinish() async throws {
    let store = MonthlyUsageStore(database: try .inMemory())
    let source = source(store)
    let settings = try configuredSettings()
    let first = try await ready(source, settings: settings)

    #expect(await reason(source, settings: settings) == .previousRefinementInProgress)
    await first.finish()
    _ = try await ready(source, settings: settings)
  }

  @Test("AI-04: 使用量の保存先を開けなければ送信しない")
  func unavailableStoreBlocksSending() async throws {
    struct OpenFailure: Error {}
    let source = UsageStoreBudgetSource(
      makeStore: { throw OpenFailure() }, pendingReservationURL: pendingURL, calendar: calendar)

    #expect(await reason(source, settings: try configuredSettings()) == .usageUnavailable)
  }

  @Test("AI-04: 読めない予約が残っていたら、起動し直しても送信しない")
  func corruptedPendingReservationBlocksSending() async throws {
    let store = MonthlyUsageStore(database: try .inMemory())
    try FileManager.default.createDirectory(at: directory.url, withIntermediateDirectories: true)
    try Data("broken".utf8).write(to: pendingURL)
    let source = source(store)
    let settings = try configuredSettings()

    #expect(await reason(source, settings: settings) == .usageUnavailable)
    #expect(await reason(source, settings: settings) == .usageUnavailable)
    #expect(await source.isDisabledByPersistenceFailure)
    // 予約を消さないため、起動し直しても送信しない
    #expect(await reason(self.source(store), settings: settings) == .usageUnavailable)
  }
}
