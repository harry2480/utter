import Foundation
import Testing
import UtterAI
import UtterCore
import UtterPersistence
import UtterText

/// セッションの整形の結線（TXT-03, AI-01, AI-03, AI-04, AC-06, AC-12, CTX-01〜03）。
/// Claude API への送信は数えるだけの送信部に置き換え、ネットワークに出ない。
@MainActor
struct SessionRefinementPipelineTests {
  private static let transcript = "えーと明日の会議は10時からです"
  private static let safeInput = SensitiveInputContext(
    secureField: .off, secureEventInput: .off, app: "com.example.editor")

  private let suite: TestDefaults
  private let database: UtterDatabase

  init() throws {
    suite = try TestDefaults()
    database = try UtterDatabase.inMemory()
  }

  private var store: AppSettingsStore { AppSettingsStore(defaults: suite.defaults) }

  private func pipeline(
    _ settings: AppSettings,
    apiKeyStore: StubAPIKeyStore = RefinementSettings.apiKeyStore(),
    transport: CountingTransport
  ) throws -> SessionRefinementPipeline {
    try store.save(settings)
    let database = database
    return SessionRefinementPipeline(
      settingsStore: store, apiKeyStore: apiKeyStore, database: { database },
      makeProvider: { configuration, keys in
        ClaudeProvider(apiKeyStore: keys, configuration: configuration, transport: transport)
      },
      now: { RefinementSettings.now }, calendar: RefinementSettings.calendar)
  }

  private func refine(
    _ pipeline: SessionRefinementPipeline,
    _ transcript: String = transcript,
    app: String? = "com.example.editor",
    input: SensitiveInputContext = safeInput
  ) async throws -> SessionRefinementResult {
    try await pipeline.refine(transcript, frontmostApp: app, sensitivity: { input })
  }

  private static func localBasic(
    _ text: String = transcript, mode: RefinementMode = .natural, terms: [String] = []
  ) -> String {
    LocalBasicRefiner().refine(
      RefinementRequest(text: text, mode: mode, style: .standard, dictionaryTerms: terms))
  }

  // MARK: 送信する

  @Test("AI-01, AC-06: 処理系・同意・API キー・予算がそろえば Claude へ1回だけ送り、応答を使う")
  func sendsWhenEverythingIsReady() async throws {
    let transport = CountingTransport()
    let result = try await refine(pipeline(RefinementSettings.ready(), transport: transport))

    #expect(transport.count == 1)
    #expect(result.route == .cloud)
    #expect(result.text == "明日の会議は10時からです。")
  }

  @Test("AI-05: 送信したら推定費用を累計に記録する")
  func recordsEstimatedCost() async throws {
    let transport = CountingTransport()
    _ = try await refine(pipeline(RefinementSettings.ready(), transport: transport))

    let entries = try MonthlyUsageStore(database: database).entries()
    #expect(entries.count == 1)
    #expect(entries.first?.currencyCode == "USD")
    #expect((entries.first?.amount ?? 0) > 0)
  }

  @Test("CTX-03: 送信する本文に前面アプリの bundle ID を含めない")
  func doesNotSendBundleID() async throws {
    let transport = CountingTransport()
    _ = try await refine(
      pipeline(RefinementSettings.ready(), transport: transport), app: "com.example.secretapp")

    #expect(transport.count == 1)
    #expect(transport.bodies.allSatisfy { !$0.contains("com.example.secretapp") })
  }

  // MARK: 送信しない（送信 0 件）

  enum Missing: String, CaseIterable, Sendable {
    case localEngine
    case consent
    case apiKey
    case apiKeyUnreadable
    case budget
    case priceTable
    case currencyMismatch
  }

  @Test(
    "AI-03, AC-06, AC-12, AI-04: 条件が1つでも欠ければ送らず（送信 0 件）、Local Basic で整形する",
    arguments: Missing.allCases)
  func fallsBackToLocalBasic(_ missing: Missing) async throws {
    var settings = RefinementSettings.ready()
    let keys = RefinementSettings.apiKeyStore()
    let expected: SessionRefinementRoute.LocalReason
    switch missing {
    case .localEngine:
      settings.refinementEngine = .localBasic
      expected = .localEngineSelected
    case .consent:
      settings.consentState = ConsentState()
      expected = .consentNotGranted
    case .apiKey:
      try keys.delete()
      expected = .apiKeyNotSet
    case .apiKeyUnreadable:
      keys.setFailure(.operationFailed(code: -25308), for: .load)
      expected = .apiKeyUnavailable
    case .budget:
      settings.monthlyBudget = nil
      expected = .budgetUnavailable
    case .priceTable:
      settings.priceTable = PriceTableSetting()
      expected = .budgetUnavailable
    case .currencyMismatch:
      settings.monthlyBudget = MonthlyBudgetSetting(limitAmount: 10, currencyCode: "JPY")
      expected = .budgetUnavailable
    }
    let transport = CountingTransport()

    let result = try await refine(pipeline(settings, apiKeyStore: keys, transport: transport))

    #expect(transport.count == 0)
    #expect(result.route == .localOnly(expected))
    #expect(result.text == Self.localBasic())
  }

  @Test("AC-06: ほかの送信先・送信内容への同意では Claude へ送らない")
  func otherConsentDoesNotAllowClaude() async throws {
    var settings = RefinementSettings.ready()
    var consent = ConsentState()
    for scope in ConsentScope.allCases where scope != .transmission(.textRefinement(.claude)) {
      consent.grant(scope)
    }
    settings.consentState = consent
    let transport = CountingTransport()

    let result = try await refine(pipeline(settings, transport: transport))

    #expect(transport.count == 0)
    #expect(result.route == .localOnly(.consentNotGranted))
  }

  @Test(
    "AC-12, 7章: パスワード欄・セキュア入力・除外アプリ・判定できない入力先なら送らない（送信 0 件）",
    arguments: [
      SensitiveInputContext(secureField: .on, secureEventInput: .off, app: "com.example.editor"),
      SensitiveInputContext(secureField: .off, secureEventInput: .on, app: "com.example.editor"),
      SensitiveInputContext(secureField: .unknown, secureEventInput: .off, app: nil),
      SensitiveInputContext(
        secureField: .off, secureEventInput: .unknown, app: "com.example.editor"),
      SensitiveInputContext(secureField: .off, secureEventInput: .off, app: "com.example.excluded"),
    ])
  func sensitiveInputIsNotSent(_ input: SensitiveInputContext) async throws {
    let transport = CountingTransport()
    let settings = RefinementSettings.ready(excludedApps: ["com.example.excluded"])

    let result = try await refine(pipeline(settings, transport: transport), input: input)

    #expect(transport.count == 0)
    #expect(result.route == .localOnly(.sensitiveInput))
    #expect(result.text == Self.localBasic())
  }

  @Test("TXT-01: Raw モードは送らず、置換もせずに認識結果をそのまま使う")
  func rawIsNotSent() async throws {
    try DictionaryStore(database: database).saveRule(
      StoredReplacementRule(pattern: "会議", replacement: "ミーティング"))
    let transport = CountingTransport()

    let result = try await refine(
      pipeline(RefinementSettings.ready(mode: .raw), transport: transport))

    #expect(transport.count == 0)
    #expect(result.route == .localOnly(.rawMode))
    #expect(result.text == Self.transcript)
  }

  @Test("TXT-01: Raw モードは辞書を読まない（データベースを開かない）")
  func rawDoesNotOpenDatabase() async throws {
    try store.save(RefinementSettings.ready(mode: .raw))
    let pipeline = SessionRefinementPipeline(
      settingsStore: store, apiKeyStore: RefinementSettings.apiKeyStore(),
      database: {
        Issue.record("Raw でデータベースを開いた")
        throw CancellationError()
      })

    let result = try await refine(pipeline)

    #expect(result == SessionRefinementResult(text: Self.transcript, route: .localOnly(.rawMode)))
  }

  @Test("AI-04: 予算の残りが見込み費用に足りなければ送らず（送信 0 件）、ローカル整形に退避する")
  func budgetExceededIsNotSent() async throws {
    let transport = CountingTransport()

    let result = try await refine(
      pipeline(RefinementSettings.ready(budgetLimit: 0.000_001), transport: transport))

    #expect(transport.count == 0)
    #expect(result.route == .cloudFallback(.providerFailed(.budgetExceeded)))
    #expect(result.text == Self.localBasic())
  }

  @Test("4.1節: 送信が失敗したら再送せず、ローカル整形の結果に退避する")
  func providerFailureFallsBack() async throws {
    let transport = CountingTransport(.status(500))

    let result = try await refine(pipeline(RefinementSettings.ready(), transport: transport))

    #expect(transport.count == 1)
    guard case .cloudFallback(.providerFailed) = result.route else {
      Issue.record("退避していない: \(result.route)")
      return
    }
    #expect(result.text == Self.localBasic())
  }

  // MARK: 辞書

  @Test("TXT-03: 保存した置換ルールをローカル整形の前に適用する")
  func appliesDictionaryLocally() async throws {
    try DictionaryStore(database: database).saveRule(
      StoredReplacementRule(pattern: "会議", replacement: "ミーティング"))
    var settings = RefinementSettings.ready()
    settings.refinementEngine = .localBasic
    let transport = CountingTransport()

    let result = try await refine(pipeline(settings, transport: transport))

    #expect(transport.count == 0)
    #expect(result.text == Self.localBasic("えーと明日のミーティングは10時からです"))
  }

  @Test("TXT-03, CTX-03: クラウドへは置換後の本文と辞書語を送る")
  func sendsReplacedTextAndTerms() async throws {
    let dictionary = DictionaryStore(database: database)
    try dictionary.saveRule(StoredReplacementRule(pattern: "teh", replacement: "the"))
    try dictionary.addTerm("Utterly")
    let transport = CountingTransport(.success(text: "明日の会議は10時からです the。"))

    _ = try await refine(
      pipeline(RefinementSettings.ready(), transport: transport),
      "えーと明日の会議は10時からです teh")

    let body = try #require(transport.bodies.first)
    #expect(body.contains("the"))
    #expect(!body.contains("teh"))
    #expect(body.contains("Utterly"))
  }

  @Test("4.1節: 辞書を読めなくても、置換なしで整形を続ける")
  func unreadableDictionaryStillRefines() async throws {
    var settings = RefinementSettings.ready()
    settings.refinementEngine = .localBasic
    try store.save(settings)
    let pipeline = SessionRefinementPipeline(
      settingsStore: store, apiKeyStore: RefinementSettings.apiKeyStore(),
      database: { throw CancellationError() })

    let result = try await refine(pipeline)

    #expect(result.text == Self.localBasic())
  }

  @Test("AI-05: 推定費用の累計を開けなければ送らない（送信 0 件）")
  func unreadableUsageIsNotSent() async throws {
    try store.save(RefinementSettings.ready())
    let transport = CountingTransport()
    let pipeline = SessionRefinementPipeline(
      settingsStore: store, apiKeyStore: RefinementSettings.apiKeyStore(),
      database: { throw CancellationError() },
      makeProvider: { configuration, keys in
        ClaudeProvider(apiKeyStore: keys, configuration: configuration, transport: transport)
      },
      now: { RefinementSettings.now }, calendar: RefinementSettings.calendar)

    let result = try await refine(pipeline)

    #expect(transport.count == 0)
    #expect(result.route == .localOnly(.budgetUnavailable))
  }
}
