import Foundation
import Testing
import UtterAI
import UtterCore
import UtterPersistence

@testable import UtteriOSKit

/// 同意・API キー・予算の有無で、クラウド整形へ送るかローカル整形だけにするかを確かめる（iOS-10, AC-06, AC-12, AI-04）。
@MainActor
struct CloudRefinementTests {
  private let temporaryDefaults: TemporaryDefaults
  private let settingsStore: AppSettingsStore
  private let keyStore = StubAPIKeyStore()
  private let provider = StubAIProvider(behavior: .respond("明日の会議は10時からです。"))
  private let spoken = "えーと明日の会議は10時からです"
  private let date = Date(timeIntervalSince1970: 1_800_000_000)

  init() throws {
    temporaryDefaults = try TemporaryDefaults()
    settingsStore = AppSettingsStore(defaults: temporaryDefaults.defaults)
    // 既定は Local Basic。各テストは処理系にクラウド AI を選んだ状態から始める
    try settingsStore.save(AppSettings(refinementEngine: .cloudAI))
  }

  private var request: RefinementRequest { RefinementRequest(text: spoken, mode: .natural) }

  private var localText: String { LocalBasicRefiner().refine(request) }

  private func month() throws -> YearMonth { try YearMonth(year: 2027, month: 1) }

  private func cloud(
    budgetSource: any CloudRefinementBudgetSource,
    sensitivity: @escaping @Sendable () -> SensitiveInputDecision = { .allowedInput }
  ) -> CloudRefinement {
    let provider = provider
    let date = date
    return CloudRefinement(
      settingsStore: settingsStore, apiKeyStore: keyStore, budgetSource: budgetSource,
      makeProvider: { _, _ in provider }, date: { date }, sensitivity: sensitivity)
  }

  private func setConsent(_ granted: Bool) throws {
    try ConsentSettingsController(store: settingsStore).setGranted(
      granted, for: CloudFixtures.claudeConsent)
  }

  private func saveKey() throws {
    try keyStore.save(APIKey("sk-ant-test"))
  }

  @Test("iOS-10, AC-06: 同意していなければ API キーも予算も確かめず、送信せずに Local Basic で整形する")
  func noConsentStaysLocal() async throws {
    try saveKey()
    let budget = StubBudgetSource(budget: try CloudFixtures.generousBudget(month: month()))

    let result = try await cloud(budgetSource: budget).refine(
      request, localRefiner: LocalBasicRefiner())

    #expect(
      result == SessionRefinementResult(text: localText, route: .localOnly(.consentNotGranted)))
    #expect(await provider.callCount == 0)
    #expect(await budget.beginCount == 0)
    #expect(keyStore.calls == [.save])
  }

  @Test("AI-03, iOS-10: 処理系に Local Basic を選んでいれば、同意・API キー・予算があっても送信しない")
  func localEngineStaysLocal() async throws {
    try settingsStore.save(AppSettings(refinementEngine: .localBasic))
    try setConsent(true)
    try saveKey()
    let budget = StubBudgetSource(budget: try CloudFixtures.generousBudget(month: month()))

    let result = try await cloud(budgetSource: budget).refine(
      request, localRefiner: LocalBasicRefiner())

    #expect(
      result == SessionRefinementResult(text: localText, route: .localOnly(.localEngineSelected)))
    #expect(await provider.callCount == 0)
    #expect(await budget.beginCount == 0)
  }

  @Test("AI-03: 予算の確認を待つ間に処理系を Local Basic に戻したら、送信せずに予算の記録を終える")
  func switchToLocalWhileCheckingBudgetStopsSending() async throws {
    try setConsent(true)
    try saveKey()
    let suiteName = temporaryDefaults.suiteName
    let budget = StubBudgetSource(budget: try CloudFixtures.generousBudget(month: month())) {
      await MainActor.run {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return }
        let store = AppSettingsStore(defaults: defaults)
        var settings = store.load()
        settings.refinementEngine = .localBasic
        try? store.save(settings)
      }
    }

    let result = try await cloud(budgetSource: budget).refine(
      request, localRefiner: LocalBasicRefiner())

    #expect(result.route == .localOnly(.localEngineSelected))
    #expect(await provider.callCount == 0)
    #expect(await budget.finishCount == 1)
  }

  @Test("iOS-10, AC-12: 同意していても API キーが未設定なら、予算を予約せず送信もしない")
  func consentWithoutKeyStaysLocal() async throws {
    try setConsent(true)
    let budget = StubBudgetSource(budget: try CloudFixtures.generousBudget(month: month()))

    let result = try await cloud(budgetSource: budget).refine(
      request, localRefiner: LocalBasicRefiner())

    #expect(result == SessionRefinementResult(text: localText, route: .localOnly(.apiKeyNotSet)))
    #expect(await provider.callCount == 0)
    #expect(await budget.beginCount == 0)
  }

  @Test("iOS-10, AC-12: API キーを読み出せなければ（端末のロック中など）送信しない")
  func unreadableKeyStaysLocal() async throws {
    try setConsent(true)
    try saveKey()
    keyStore.setFailure(.operationFailed(code: -25308), for: .load)
    let budget = StubBudgetSource(budget: try CloudFixtures.generousBudget(month: month()))

    let result = try await cloud(budgetSource: budget).refine(
      request, localRefiner: LocalBasicRefiner())

    #expect(result.route == .localOnly(.apiKeyUnavailable))
    #expect(result.text == localText)
    #expect(await provider.callCount == 0)
  }

  @Test("iOS-10, AI-04: 同意と API キーがあっても、設定した予算の上限を確かめられなければ送信しない")
  func noBudgetStaysLocal() async throws {
    try setConsent(true)
    try saveKey()
    let budget = StubBudgetSource(budget: nil)

    let result = try await cloud(budgetSource: budget).refine(
      request, localRefiner: LocalBasicRefiner())

    #expect(
      result
        == SessionRefinementResult(
          text: localText, route: .localOnly(.budgetUnavailable(.notConfigured))))
    #expect(await provider.callCount == 0)
    #expect(await budget.beginCount == 1)
  }

  @Test("iOS-10, AI-04: 月次予算が未設定なら、同意と API キーがあれば上限なしで Claude へ1回だけ送る")
  func unlimitedBudgetRefinesWithCloud() async throws {
    try setConsent(true)
    try saveKey()
    let budget = StubBudgetSource(budget: nil, unlimited: true)

    let result = try await cloud(budgetSource: budget).refine(
      request, localRefiner: LocalBasicRefiner())

    #expect(result == SessionRefinementResult(text: "明日の会議は10時からです。", route: .cloud))
    #expect(await provider.callCount == 1)
    #expect(await budget.beginCount == 1)
    // 予算を用意していないため、推定費用の記録は呼ばない
    #expect(await budget.finishCount == 0)
  }

  @Test("iOS-10: 同意・API キー・予算がそろえば Claude へ1回だけ送り、応答で整形して推定費用を記録する")
  func allPresentRefinesWithCloud() async throws {
    try setConsent(true)
    try saveKey()
    let budget = StubBudgetSource(budget: try CloudFixtures.generousBudget(month: month()))

    let result = try await cloud(budgetSource: budget).refine(
      request, localRefiner: LocalBasicRefiner())

    #expect(result == SessionRefinementResult(text: "明日の会議は10時からです。", route: .cloud))
    #expect(await provider.receivedRequests == [request])
    #expect(await budget.finishCount == 1)
  }

  @Test("7章, AC-12: 機密入力と判定されたら、同意・API キー・予算がそろっていても送信せず Local Basic に退避する")
  func sensitiveInputStaysLocal() async throws {
    try setConsent(true)
    try saveKey()
    let budget = StubBudgetSource(budget: try CloudFixtures.generousBudget(month: month()))

    let result = try await cloud(budgetSource: budget, sensitivity: { .secureFieldInput }).refine(
      request, localRefiner: LocalBasicRefiner())

    #expect(
      result
        == SessionRefinementResult(
          text: localText, route: .cloudFallback(.sensitiveInputSuppressed)))
    #expect(RefinementNotice(route: result.route) == .sensitiveInput)
    #expect(await provider.callCount == 0)
    #expect(await budget.finishCount == 1)
  }

  @Test("7章, AC-12: 本体アプリの判定は自アプリの bundle ID で許可し、bundle ID が取れなければ送信しない")
  func ownAppSensitivity() {
    let own = CloudRefinement.ownAppSensitivity(bundleIdentifier: "com.example.utter")()
    #expect(own.allowsCloudTransmission)
    let unknown = CloudRefinement.ownAppSensitivity(bundleIdentifier: nil)()
    #expect(!unknown.allowsCloudTransmission)
    #expect(unknown.reasons == [.undetermined])
  }

  @Test("4.1節, AI-06: クラウド整形に失敗したら Local Basic の結果に退避し、理由を残す")
  func providerFailureFallsBackToLocal() async throws {
    try setConsent(true)
    try saveKey()
    await provider.setBehavior(.fail(.networkUnavailable))
    let budget = StubBudgetSource(budget: try CloudFixtures.generousBudget(month: month()))

    let result = try await cloud(budgetSource: budget).refine(
      request, localRefiner: LocalBasicRefiner())

    #expect(result.text == localText)
    #expect(result.route == .cloudFallback(.providerFailed(.networkUnavailable)))
    #expect(await provider.callCount == 1)
    #expect(await budget.finishCount == 1)
  }

  @Test("AC-06: 予算の確認を待つ間に同意を撤回したら、送信しない")
  func revokeWhileCheckingBudgetStopsSending() async throws {
    try setConsent(true)
    try saveKey()
    // AppSettingsStore は Sendable でないため、同じ suite を別に開いて撤回する
    let suiteName = temporaryDefaults.suiteName
    let budget = StubBudgetSource(budget: try CloudFixtures.generousBudget(month: month())) {
      await MainActor.run {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return }
        _ = try? ConsentSettingsController(store: AppSettingsStore(defaults: defaults)).setGranted(
          false, for: CloudFixtures.claudeConsent)
      }
    }

    let result = try await cloud(budgetSource: budget).refine(
      request, localRefiner: LocalBasicRefiner())

    #expect(
      result == SessionRefinementResult(text: localText, route: .localOnly(.consentNotGranted)))
    #expect(await provider.callCount == 0)
    #expect(await budget.finishCount == 1)
  }

  @Test("TXT-01: Raw モードは同意・API キー・予算があっても送信しない")
  func rawModeDoesNotSend() async throws {
    try setConsent(true)
    try saveKey()
    let budget = StubBudgetSource(budget: try CloudFixtures.generousBudget(month: month()))
    let raw = RefinementRequest(text: spoken, mode: .raw)

    let result = try await cloud(budgetSource: budget).refine(
      raw, localRefiner: LocalBasicRefiner())

    #expect(result == SessionRefinementResult(text: spoken, route: .localOnly(.rawMode)))
    #expect(await provider.callCount == 0)
    #expect(await budget.beginCount == 0)
  }

  @Test("iOS-10: 整形の結果の文字列表現に本文を出さない")
  func resultDescriptionHidesText() {
    let result = SessionRefinementResult(text: spoken, route: .cloud)

    #expect(!String(describing: result).contains(spoken))
    #expect(!String(reflecting: result).contains(spoken))
  }
}
