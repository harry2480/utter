import Foundation
import Testing
import UtterAI
import UtterCore
import UtterPersistence
import UtterText

/// Edit Mode の送信の結線（AC-14, AC-06, AC-12, AI-04, AI-05, CTX-03）。
/// Claude API への送信は数えるだけの送信部に置き換え、ネットワークに出ない。
@MainActor
struct EditModeRequestPipelineTests {
  private static let allowed = SensitiveInputPolicy().decide(
    SensitiveInputContext(secureField: .off, secureEventInput: .off, app: "com.example.editor"))
  private static let secure = SensitiveInputPolicy().decide(
    SensitiveInputContext(secureField: .on, secureEventInput: .off, app: "com.example.editor"))

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
  ) throws -> EditModeRequestPipeline {
    try store.save(settings)
    let database = database
    return EditModeRequestPipeline(
      settingsStore: store, apiKeyStore: apiKeyStore, database: { database },
      makeProvider: { configuration, keys in
        ClaudeProvider(apiKeyStore: keys, configuration: configuration, transport: transport)
      },
      now: { RefinementSettings.now }, calendar: RefinementSettings.calendar)
  }

  /// 選択テキストの送信の同意を確かめて作った送信内容
  private static func request() throws -> EditRequest {
    let session = try EditSession(selection: "明日の会議は9時からです。")
    var consent = ConsentState()
    consent.grant(.transmission(.editSelection(.claude)))
    let transmission = try session.cloudTransmission(to: .claude, consent: consent)
    return EditRequest(transmission, instruction: "10時に直して", dictionaryTerms: ["会議"])
  }

  private func send(
    _ pipeline: EditModeRequestPipeline,
    decision: SensitiveInputDecision = EditModeRequestPipelineTests.allowed
  ) async throws -> EditSendResult {
    try await pipeline.send(try Self.request(), sensitivity: { decision })
  }

  @Test("AC-14, AC-06: 同意・API キー・予算がそろえば Claude へ1回だけ送り、編集案を返す")
  func sendsWhenEverythingIsReady() async throws {
    let transport = CountingTransport()
    let result = try await send(pipeline(RefinementSettings.readyForEdit(), transport: transport))

    #expect(transport.count == 1)
    #expect(result.outcome?.proposedText == "明日の会議は10時からです。")
    // 推定費用は整形と同じ累計に記録する（AI-05）
    #expect(try MonthlyUsageStore(database: database).entries().count == 1)
  }

  @Test("AC-06: 整形の送信に同意していても、選択テキストの送信に同意していなければ送らない")
  func requiresEditSelectionConsent() async throws {
    let settings = RefinementSettings.ready()
    #expect(settings.consentState.allows(.textRefinement(.claude)))
    let transport = CountingTransport()

    let result = try await send(pipeline(settings, transport: transport))

    #expect(result == .outcome(EditOutcome(content: .notEdited(.consentNotGranted))))
    #expect(transport.count == 0)
  }

  @Test("AC-12: API キーが保存されていなければ送らない")
  func requiresAPIKey() async throws {
    let transport = CountingTransport()

    let result = try await send(
      pipeline(
        RefinementSettings.readyForEdit(), apiKeyStore: StubAPIKeyStore(), transport: transport))

    #expect(result == .unavailable(.apiKeyNotSet))
    #expect(transport.count == 0)
  }

  @Test("7章, AC-12: 入力先が機密入力なら送らない")
  func sensitiveInputIsNotSent() async throws {
    let transport = CountingTransport()

    let result = try await send(
      pipeline(RefinementSettings.readyForEdit(), transport: transport), decision: Self.secure)

    #expect(result == .outcome(EditOutcome(content: .notEdited(.sensitiveInputSuppressed))))
    #expect(transport.count == 0)
  }

  @Test("AI-04, AI-05: 予算・単価表が未設定なら、整形と同じく送らない")
  func requiresBudget() async throws {
    var settings = RefinementSettings.readyForEdit()
    settings.monthlyBudget = nil
    let transport = CountingTransport()

    let result = try await send(pipeline(settings, transport: transport))

    #expect(result == .unavailable(.budgetUnavailable))
    #expect(transport.count == 0)
  }

  @Test("AI-04: 予算の上限を超えるなら送らない")
  func budgetExceeded() async throws {
    let transport = CountingTransport()

    let result = try await send(
      pipeline(RefinementSettings.readyForEdit(budgetLimit: 0.000_001), transport: transport))

    #expect(result == .outcome(EditOutcome(content: .notEdited(.providerFailed(.budgetExceeded)))))
    #expect(transport.count == 0)
  }

  @Test("AC-14: 保存した辞書語を、送ってよい文脈として読む")
  func dictionaryTerms() async throws {
    try DictionaryStore(database: database).replaceAll(terms: ["会議", "utter"], rules: [])
    let pipeline = try pipeline(RefinementSettings.readyForEdit(), transport: CountingTransport())

    let terms = await pipeline.dictionaryTerms()
    #expect(terms.count == 2)
    #expect(Set(terms) == ["会議", "utter"])
  }
}

extension RefinementSettings {
  /// Edit Mode の送信の条件（選択テキストの送信の同意・予算・単価表）がそろった設定
  static func readyForEdit(budgetLimit: Decimal = 10) -> AppSettings {
    var settings = ready(budgetLimit: budgetLimit)
    settings.consentState.grant(.transmission(.editSelection(.claude)))
    return settings
  }
}

extension EditSendResult {
  /// 送った結果。送らなかった（`unavailable`）なら `nil`
  fileprivate var outcome: EditOutcome? {
    guard case .outcome(let outcome) = self else { return nil }
    return outcome
  }
}
