import Foundation
import Testing
import UtterAI
import UtterCore
import UtterPersistence

/// OpenAI API キー方式による整形の結線（AI-01, AI-04, AI-05, AC-05, AC-06, CTX-03, #58）。
/// OpenAI・Sign in with ChatGPT・Claude への送信は数えるだけの送信部に置き換え、ネットワークに出ない。
@MainActor
struct SessionOpenAIRefinementTests {
  private static let transcript = "えーと明日の会議は10時からです"
  private static let safeInput = SensitiveInputContext(
    secureField: .off, secureEventInput: .off, app: "com.example.editor")
  private static let model = "test-openai-model"

  private let suite: TestDefaults
  private let database: UtterDatabase

  init() throws {
    suite = try TestDefaults()
    database = try UtterDatabase.inMemory()
  }

  private var store: AppSettingsStore { AppSettingsStore(defaults: suite.defaults) }

  /// OpenAI API キー方式で送る条件（処理系・送信先・モデル名・同意・予算と単価表）がそろった設定。
  /// Claude の条件もそろえておき、切り替えないことを確かめる
  private static func ready(budgetLimit: Decimal = 10) -> AppSettings {
    var settings = RefinementSettings.ready(budgetLimit: budgetLimit)
    settings.cloudRefinementProvider = .openAIAPIKey
    settings.openAIRefinementModel = model
    settings.chatGPTRefinementModel = "test-plan-model"
    settings.consentState.grant(.transmission(.textRefinement(.chatGPT)))
    settings.priceTable = PriceTableSetting(
      currencyCode: "USD", updatedOn: CalendarDay(year: 2026, month: 10, day: 1),
      prices: [
        ModelPriceSetting(
          model: AppSettings.defaultRefinementModel, inputPerMillionTokens: 1,
          outputPerMillionTokens: 5),
        ModelPriceSetting(model: model, inputPerMillionTokens: 1, outputPerMillionTokens: 2),
      ].compactMap { $0 })
    return settings
  }

  /// 使用量つきで `response.completed` まで届くストリーム
  private nonisolated static func completed(_ text: String) -> String {
    [
      #"{"type":"response.output_text.delta","delta":"\#(text)"}"#,
      #"{"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":120,"output_tokens":15}}}"#,
    ].map { "data: \($0)\n\n" }.joined()
  }

  /// 保存済みの OpenAI API キー（Claude API キーとは別の値）
  private static func openAIKeys() -> StubAPIKeyStore {
    StubAPIKeyStore(key: try? APIKey("sk-openai-test-secret"))
  }

  private struct Transports {
    let openAI: PlanStreamingTransport
    let plan = PlanStreamingTransport()
    let claude: CountingTransport

    init(
      openAI: PlanStreamingTransport = PlanStreamingTransport(
        body: completed("明日の会議は10時からです。")),
      claude: CountingTransport = CountingTransport()
    ) {
      self.openAI = openAI
      self.claude = claude
    }
  }

  private func refine(
    _ settings: AppSettings, transports: Transports,
    openAIKeys: StubAPIKeyStore? = SessionOpenAIRefinementTests.openAIKeys(),
    claudeKeys: StubAPIKeyStore = RefinementSettings.apiKeyStore(),
    sent: SentDestinations = SentDestinations()
  ) async throws -> SessionRefinementResult {
    try store.save(settings)
    let database = database
    let pipeline = SessionRefinementPipeline(
      settingsStore: store, apiKeyStore: claudeKeys, database: { database },
      makeProvider: { configuration, keys in
        ClaudeProvider(
          apiKeyStore: keys, configuration: configuration, transport: transports.claude)
      },
      chatGPTAccount: ChatGPTAccountSession(
        store: StubChatGPTAccountStore.signedIn(planUsage: true),
        authClient: StubChatGPTAuthClient()),
      makeChatGPTProvider: { configuration, account in
        ChatGPTPlanProvider(
          account: account, configuration: configuration, transport: transports.plan)
      },
      openAIAPIKeyStore: openAIKeys,
      makeOpenAIProvider: { configuration, apiKey in
        OpenAIProvider(
          apiKey: apiKey.value, configuration: configuration, transport: transports.openAI)
      },
      now: { RefinementSettings.now }, calendar: RefinementSettings.calendar)
    return try await pipeline.refine(
      Self.transcript, frontmostApp: "com.example.secretapp", sensitivity: { Self.safeInput },
      willSend: { sent.append($0) })
  }

  private static func localBasic() -> String {
    LocalBasicRefiner().refine(RefinementRequest(text: transcript, mode: .natural))
  }

  @Test("AC-05, AC-06, AI-05: 条件がそろえば OpenAI API キーで1回だけ送り、推定費用を記録し、ほかの送信先へは送らない")
  func sendsToOpenAIWhenReady() async throws {
    let transports = Transports()
    let sent = SentDestinations()
    let result = try await refine(Self.ready(), transports: transports, sent: sent)

    #expect(result.route == .cloud)
    #expect(result.text == "明日の会議は10時からです。")
    #expect(transports.openAI.count == 1)
    #expect(transports.plan.count == 0)
    #expect(transports.claude.count == 0)
    // HUD には文字を送る先として ChatGPT を出す
    #expect(sent.kinds == [.chatGPT])
    // OpenAI API キーで送り、Claude API キーは使わない
    #expect(transports.openAI.authorizations == ["Bearer sk-openai-test-secret"])
    // 利用者が設定したモデル名で送る（AI-07）
    #expect(transports.openAI.bodies.allSatisfy { $0.contains(Self.model) })
    // CTX-03: 前面アプリの bundle ID を送らない
    #expect(transports.openAI.bodies.allSatisfy { !$0.contains("com.example.secretapp") })
    // トークン課金のため、Claude と同じ累計に推定費用を記録する（AI-05）
    let entries = try MonthlyUsageStore(database: database).entries()
    #expect(entries.count == 1)
    #expect(entries.first?.currencyCode == "USD")
  }

  enum Missing: String, CaseIterable, Sendable {
    case consent
    case claudeConsentOnly
    case apiKey
    case apiKeyStore
    case model
    case budget
  }

  @Test(
    "AC-06, AI-04: 条件が1つでも欠ければ、どの送信先へも送らず Local Basic で整形する",
    arguments: Missing.allCases)
  func fallsBackToLocalBasic(_ missing: Missing) async throws {
    var settings = Self.ready()
    var openAIKeys: StubAPIKeyStore? = Self.openAIKeys()
    let expected: SessionRefinementRoute.LocalReason
    switch missing {
    case .consent:
      settings.consentState = ConsentState()
      expected = .consentNotGranted
    case .claudeConsentOnly:
      // 別の送信先（Claude）への同意では送らない
      settings.consentState = ConsentState()
      settings.consentState.grant(.transmission(.textRefinement(.claude)))
      expected = .consentNotGranted
    case .apiKey:
      // Claude API キーがあっても、OpenAI API キーがなければ送らない
      openAIKeys = StubAPIKeyStore()
      expected = .apiKeyNotSet
    case .apiKeyStore:
      openAIKeys = nil
      expected = .cloudUnavailable
    case .model:
      settings.openAIRefinementModel = ""
      expected = .cloudUnavailable
    case .budget:
      settings.monthlyBudget = nil
      expected = .budgetUnavailable
    }
    let transports = Transports()
    let sent = SentDestinations()

    let result = try await refine(
      settings, transports: transports, openAIKeys: openAIKeys, sent: sent)

    #expect(transports.openAI.count == 0)
    #expect(transports.plan.count == 0)
    #expect(transports.claude.count == 0)
    #expect(sent.kinds.isEmpty)
    #expect(result.route == .localOnly(expected))
    #expect(result.text == Self.localBasic())
  }

  @Test("AC-06: 同意がなければ OpenAI API キーを Keychain から読まない")
  func doesNotReadKeyWithoutConsent() async throws {
    var settings = Self.ready()
    settings.consentState = ConsentState()
    let openAIKeys = Self.openAIKeys()
    let claudeKeys = RefinementSettings.apiKeyStore()

    _ = try await refine(
      settings, transports: Transports(), openAIKeys: openAIKeys, claudeKeys: claudeKeys)

    #expect(openAIKeys.calls.isEmpty)
    #expect(claudeKeys.calls.isEmpty)
  }

  @Test("AC-12: OpenAI API キーを読み出せなければ送らない")
  func keyUnavailable() async throws {
    let openAIKeys = Self.openAIKeys()
    openAIKeys.setFailure(.operationFailed(code: -25308), for: .load)
    let transports = Transports()

    let result = try await refine(Self.ready(), transports: transports, openAIKeys: openAIKeys)

    #expect(transports.openAI.count == 0)
    #expect(result.route == .localOnly(.apiKeyUnavailable))
  }

  enum Budget: String, CaseIterable, Sendable {
    /// 月次予算の残りが足りない
    case exhausted
    /// 単価表に OpenAI のモデルがなく、費用を推定できない
    case modelNotPriced
  }

  @Test("AI-04, AI-05: 予算が足りない・費用を推定できないときは送らず、Local Basic へ退避する", arguments: Budget.allCases)
  func budgetBlocksSending(_ budget: Budget) async throws {
    var settings: AppSettings
    switch budget {
    case .exhausted:
      settings = Self.ready(budgetLimit: 0)
    case .modelNotPriced:
      settings = Self.ready()
      settings.priceTable = RefinementSettings.ready().priceTable
    }
    let transports = Transports()
    let sent = SentDestinations()

    let result = try await refine(settings, transports: transports, sent: sent)

    #expect(transports.openAI.count == 0)
    #expect(transports.claude.count == 0)
    #expect(sent.kinds.isEmpty)
    #expect(result.route == .cloudFallback(.providerFailed(.budgetExceeded)))
    #expect(result.text == Self.localBasic())
    #expect(try MonthlyUsageStore(database: database).entries().isEmpty)
  }

  @Test(
    "4.1節, AI-01, AI-04: 失敗したら Local Basic へ退避し、切り替えを選んでいても Sign in with ChatGPT や Claude へは切り替えない")
  func failureFallsBackWithoutSwitching() async throws {
    var settings = Self.ready()
    settings.cloudRefinementFallbackEnabled = true
    let transports = Transports(
      openAI: PlanStreamingTransport(status: 500, body: #"{"error":{"code":"server_error"}}"#))
    let sent = SentDestinations()

    let result = try await refine(settings, transports: transports, sent: sent)

    #expect(result.route == .cloudFallback(.providerFailed(.networkUnavailable)))
    #expect(result.text == Self.localBasic())
    #expect(transports.openAI.count == 1)
    #expect(transports.plan.count == 0)
    #expect(transports.claude.count == 0)
    #expect(sent.kinds == [.chatGPT])
  }

  @Test("AI-01, AI-04: Claude を選んで失敗したときの切り替え先は Sign in with ChatGPT で、OpenAI API キー方式へは切り替えない")
  func claudeFailureDoesNotSwitchToOpenAI() async throws {
    var settings = Self.ready()
    settings.cloudRefinementProvider = .claude
    settings.cloudRefinementFallbackEnabled = true
    let transports = Transports(claude: CountingTransport(.status(500)))

    let result = try await refine(settings, transports: transports)

    #expect(transports.claude.count == 1)
    #expect(transports.plan.count == 1)
    #expect(transports.openAI.count == 0)
    #expect(result.route == .cloud)
  }
}
