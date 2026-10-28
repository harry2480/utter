import Foundation
import Testing
import UtterAI
import UtterCore
import UtterPersistence

/// HUD へ知らせた送信先を順に記録する
@MainActor
final class SentDestinations {
  private(set) var kinds: [CloudAIProviderKind] = []

  func append(_ kind: CloudAIProviderKind) {
    kinds.append(kind)
  }
}

/// 失敗時に別のクラウドへ切り替える設定（AI-04, AC-06, #199）。
/// Claude と ChatGPT への送信は数えるだけの送信部に置き換え、ネットワークに出ない。
@MainActor
struct SessionCloudFallbackTests {
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

  /// Claude と ChatGPT のどちらへも送る条件（同意・API キー・予算・モデル名）がそろい、切り替えを選んだ設定
  private static func ready(selected: CloudRefinementProvider) -> AppSettings {
    var settings = RefinementSettings.ready()
    settings.cloudRefinementProvider = selected
    settings.chatGPTRefinementModel = "test-model"
    settings.consentState.grant(.transmission(.textRefinement(.chatGPT)))
    settings.cloudRefinementFallbackEnabled = true
    return settings
  }

  private func refine(
    _ settings: AppSettings, chatGPT: PlanStreamingTransport, claude: CountingTransport,
    sent: SentDestinations = SentDestinations()
  ) async throws -> SessionRefinementResult {
    try store.save(settings)
    let database = database
    let pipeline = SessionRefinementPipeline(
      settingsStore: store, apiKeyStore: RefinementSettings.apiKeyStore(),
      database: { database },
      makeProvider: { configuration, keys in
        ClaudeProvider(apiKeyStore: keys, configuration: configuration, transport: claude)
      },
      chatGPTAccount: ChatGPTAccountSession(
        store: StubChatGPTAccountStore.signedIn(planUsage: true),
        authClient: StubChatGPTAuthClient()),
      makeChatGPTProvider: { configuration, account in
        ChatGPTPlanProvider(account: account, configuration: configuration, transport: chatGPT)
      },
      now: { RefinementSettings.now }, calendar: RefinementSettings.calendar)
    return try await pipeline.refine(
      Self.transcript, frontmostApp: "com.example.editor", sensitivity: { Self.safeInput },
      willSend: { sent.append($0) })
  }

  private static func usageLimit() -> PlanStreamingTransport {
    PlanStreamingTransport(
      status: 429, body: #"{"error":{"code":"subscription_sharing_usage_limit_exceeded"}}"#)
  }

  private static func localBasic() -> String {
    LocalBasicRefiner().refine(RefinementRequest(text: transcript, mode: .natural))
  }

  @Test("AI-04: 切り替えを選んでいなければ、Claude が失敗しても ChatGPT へは送らない（既定）")
  func doesNotSwitchByDefault() async throws {
    var settings = Self.ready(selected: .claude)
    settings.cloudRefinementFallbackEnabled = false
    let chatGPT = PlanStreamingTransport()
    let claude = CountingTransport(.status(500))

    let result = try await refine(settings, chatGPT: chatGPT, claude: claude)

    #expect(claude.count == 1)
    #expect(chatGPT.count == 0)
    guard case .cloudFallback(.providerFailed) = result.route else {
      Issue.record("退避していない: \(result.route)")
      return
    }
    #expect(result.text == Self.localBasic())
  }

  @Test("AI-04, AC-06: 切り替えを選び、ChatGPT への送信に同意していれば、Claude の失敗後に ChatGPT へ1回だけ送る")
  func switchesFromClaudeToChatGPT() async throws {
    let chatGPT = PlanStreamingTransport()
    let claude = CountingTransport(.status(500))

    let sent = SentDestinations()
    let result = try await refine(
      Self.ready(selected: .claude), chatGPT: chatGPT, claude: claude, sent: sent)

    #expect(claude.count == 1)
    #expect(chatGPT.count == 1)
    // HUD の送信先は、実際に送る直前にそれぞれ知らせる
    #expect(sent.kinds == [.claude, .chatGPT])
    #expect(result.route == .cloud)
    #expect(result.text == "明日の会議は10時からです。")
    // CTX-03: 切り替え先へも前面アプリの bundle ID を送らない
    #expect(chatGPT.bodies.allSatisfy { !$0.contains("com.example.editor") })
  }

  @Test("AI-04, AC-06: 切り替えを選び、Claude への送信に同意していれば、ChatGPT の失敗後に Claude へ1回だけ送る")
  func switchesFromChatGPTToClaude() async throws {
    let chatGPT = Self.usageLimit()
    let claude = CountingTransport()

    let result = try await refine(
      Self.ready(selected: .chatGPTSignIn), chatGPT: chatGPT, claude: claude)

    #expect(chatGPT.count == 1)
    #expect(claude.count == 1)
    #expect(result.route == .cloud)
    #expect(result.text == "明日の会議は10時からです。")
  }

  @Test("AC-06: 切り替え先への送信に同意していなければ、切り替えを選んでいても送らず、最初の退避の結果を返す")
  func doesNotSwitchWithoutConsentForTarget() async throws {
    var claudeFirst = Self.ready(selected: .claude)
    claudeFirst.consentState = ConsentState()
    claudeFirst.consentState.grant(.transmission(.textRefinement(.claude)))
    let chatGPT = PlanStreamingTransport()
    let failing = CountingTransport(.status(500))
    let sent = SentDestinations()
    let fromClaude = try await refine(claudeFirst, chatGPT: chatGPT, claude: failing, sent: sent)
    #expect(chatGPT.count == 0)
    // 送らなかった切り替え先は知らせない
    #expect(sent.kinds == [.claude])
    guard case .cloudFallback(.providerFailed) = fromClaude.route else {
      Issue.record("退避していない: \(fromClaude.route)")
      return
    }

    var chatGPTFirst = Self.ready(selected: .chatGPTSignIn)
    chatGPTFirst.consentState = ConsentState()
    chatGPTFirst.consentState.grant(.transmission(.textRefinement(.chatGPT)))
    let claude = CountingTransport()
    let fromChatGPT = try await refine(chatGPTFirst, chatGPT: Self.usageLimit(), claude: claude)
    #expect(claude.count == 0)
    #expect(fromChatGPT.route == .cloudFallback(.providerFailed(.quotaExceeded)))
    #expect(fromChatGPT.text == Self.localBasic())
  }

  @Test("AC-06: 最初の送信先へ送らなかったとき（同意がないなど）は、切り替えを選んでいても切り替えない")
  func doesNotSwitchWhenFirstWasNotSent() async throws {
    var settings = Self.ready(selected: .claude)
    settings.consentState = ConsentState()
    settings.consentState.grant(.transmission(.textRefinement(.chatGPT)))
    let chatGPT = PlanStreamingTransport()
    let claude = CountingTransport()

    let result = try await refine(settings, chatGPT: chatGPT, claude: claude)

    #expect(claude.count == 0)
    #expect(chatGPT.count == 0)
    #expect(result.route == .localOnly(.consentNotGranted))
  }

  @Test("4.1節: 切り替え先も失敗したら、最初の送信先の退避の結果を返す")
  func bothFailKeepsFirstFallback() async throws {
    let chatGPT = Self.usageLimit()
    let claude = CountingTransport(.status(500))

    let result = try await refine(Self.ready(selected: .claude), chatGPT: chatGPT, claude: claude)

    #expect(claude.count == 1)
    #expect(chatGPT.count == 1)
    guard case .cloudFallback(.providerFailed) = result.route else {
      Issue.record("退避していない: \(result.route)")
      return
    }
    #expect(result.route != .cloudFallback(.providerFailed(.quotaExceeded)))
    #expect(result.text == Self.localBasic())
  }
}
