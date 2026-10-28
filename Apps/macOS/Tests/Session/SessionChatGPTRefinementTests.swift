import Foundation
import Synchronization
import Testing
import UtterAI
import UtterCore
import UtterPersistence

/// Responses API のストリームを返し、送られたリクエストを数える送信部。実ネットワークには出ない
final class PlanStreamingTransport: HTTPStreamingTransport {
  private let status: Int
  private let body: String
  private let sent = Mutex<[URLRequest]>([])

  init(status: Int = 200, body: String = PlanStreamingTransport.completed("明日の会議は10時からです。")) {
    self.status = status
    self.body = body
  }

  /// `text` を1つの差分で返し、`response.completed` で終わるストリーム
  static func completed(_ text: String) -> String {
    [
      #"{"type":"response.output_text.delta","delta":"\#(text)"}"#,
      #"{"type":"response.completed","response":{"status":"completed"}}"#,
    ].map { "data: \($0)\n\n" }.joined()
  }

  /// 送られたリクエストの数
  var count: Int { sent.withLock { $0.count } }

  /// 送られた本文（UTF-8）
  var bodies: [String] {
    sent.withLock { $0.compactMap { $0.httpBody.flatMap { String(data: $0, encoding: .utf8) } } }
  }

  /// 送られた Authorization ヘッダー
  var authorizations: [String?] {
    sent.withLock { $0.map { $0.value(forHTTPHeaderField: "authorization") } }
  }

  func bytes(for request: URLRequest) async throws -> (
    AsyncThrowingStream<UInt8, any Error>, HTTPURLResponse
  ) {
    sent.withLock { $0.append(request) }
    let url = try #require(request.url)
    let contentType = status == 200 ? "text/event-stream" : "application/json"
    let response = try #require(
      HTTPURLResponse(
        url: url, statusCode: status, httpVersion: nil,
        headerFields: ["Content-Type": contentType]))
    let (stream, continuation) = AsyncThrowingStream.makeStream(of: UInt8.self)
    for byte in Data(body.utf8) {
      continuation.yield(byte)
    }
    continuation.finish()
    return (stream, response)
  }
}

/// Sign in with ChatGPT による整形の結線（AI-01, AI-04, AC-05, AC-06, CTX-03, #50）。
/// ChatGPT と Claude への送信は数えるだけの送信部に置き換え、ネットワークに出ない。
@MainActor
struct SessionChatGPTRefinementTests {
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

  /// ChatGPT へ送る条件（処理系・送信先・モデル名・同意）がそろった設定。Claude の条件もそろえておき、切り替えないことを確かめる
  private static func ready() -> AppSettings {
    var settings = RefinementSettings.ready()
    settings.cloudRefinementProvider = .chatGPTSignIn
    settings.chatGPTRefinementModel = "test-model"
    settings.consentState.grant(.transmission(.textRefinement(.chatGPT)))
    return settings
  }

  private func pipeline(
    _ settings: AppSettings, account: ChatGPTAccountSession?,
    chatGPT: PlanStreamingTransport, claude: CountingTransport = CountingTransport()
  ) throws -> SessionRefinementPipeline {
    try store.save(settings)
    let database = database
    return SessionRefinementPipeline(
      settingsStore: store, apiKeyStore: RefinementSettings.apiKeyStore(),
      database: { database },
      makeProvider: { configuration, keys in
        ClaudeProvider(apiKeyStore: keys, configuration: configuration, transport: claude)
      },
      chatGPTAccount: account,
      makeChatGPTProvider: { configuration, account in
        ChatGPTPlanProvider(account: account, configuration: configuration, transport: chatGPT)
      },
      now: { RefinementSettings.now }, calendar: RefinementSettings.calendar)
  }

  private static func signedIn(planUsage: Bool = true) -> ChatGPTAccountSession {
    ChatGPTAccountSession(
      store: StubChatGPTAccountStore.signedIn(planUsage: planUsage),
      authClient: StubChatGPTAuthClient())
  }

  private func refine(_ pipeline: SessionRefinementPipeline) async throws
    -> SessionRefinementResult
  {
    try await pipeline.refine(
      Self.transcript, frontmostApp: "com.example.secretapp", sensitivity: { Self.safeInput })
  }

  private static func localBasic() -> String {
    LocalBasicRefiner().refine(RefinementRequest(text: transcript, mode: .natural))
  }

  @Test("AC-05, AC-06: 送信先・モデル名・同意・サインインがそろえば ChatGPT へ1回だけ送り、Claude へは送らない")
  func sendsToChatGPTWhenReady() async throws {
    let chatGPT = PlanStreamingTransport()
    let claude = CountingTransport()
    let result = try await refine(
      pipeline(Self.ready(), account: Self.signedIn(), chatGPT: chatGPT, claude: claude))

    #expect(result.route == .cloud)
    #expect(result.text == "明日の会議は10時からです。")
    #expect(chatGPT.count == 1)
    #expect(claude.count == 0)
    // 予算を使わないため、推定費用を記録しない（AI-05）
    #expect(try MonthlyUsageStore(database: database).entries().isEmpty)
    // CTX-03: 前面アプリの bundle ID を送らない
    #expect(chatGPT.bodies.allSatisfy { !$0.contains("com.example.secretapp") })
  }

  enum Missing: String, CaseIterable, Sendable {
    case consent
    case claudeConsentOnly
    case notSignedIn
    case planUsageNotGranted
    case model
    case account
  }

  @Test(
    "AC-06, S7: 条件が1つでも欠ければ ChatGPT にも Claude にも送らず、Local Basic で整形する",
    arguments: Missing.allCases)
  func fallsBackToLocalBasic(_ missing: Missing) async throws {
    var settings = Self.ready()
    var account: ChatGPTAccountSession? = Self.signedIn()
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
    case .notSignedIn:
      account = ChatGPTAccountSession(
        store: StubChatGPTAccountStore(), authClient: StubChatGPTAuthClient())
      expected = .chatGPTNotSignedIn
    case .planUsageNotGranted:
      account = Self.signedIn(planUsage: false)
      expected = .chatGPTNotSignedIn
    case .model:
      settings.chatGPTRefinementModel = ""
      expected = .cloudUnavailable
    case .account:
      account = nil
      expected = .cloudUnavailable
    }
    let chatGPT = PlanStreamingTransport()
    let claude = CountingTransport()

    let result = try await refine(
      pipeline(settings, account: account, chatGPT: chatGPT, claude: claude))

    #expect(chatGPT.count == 0)
    #expect(claude.count == 0)
    #expect(result.route == .localOnly(expected))
    #expect(result.text == Self.localBasic())
  }

  @Test("4.1節, AI-04, S7: 利用上限で失敗したら Local Basic へ退避し、Claude へは切り替えない")
  func usageLimitFallsBackWithoutSwitching() async throws {
    let chatGPT = PlanStreamingTransport(
      status: 429, body: #"{"error":{"code":"subscription_sharing_usage_limit_exceeded"}}"#)
    let claude = CountingTransport()
    let account = Self.signedIn()
    let result = try await refine(
      pipeline(Self.ready(), account: account, chatGPT: chatGPT, claude: claude))

    #expect(result.route == .cloudFallback(.providerFailed(.quotaExceeded)))
    #expect(result.text == Self.localBasic())
    #expect(chatGPT.count == 1)
    #expect(claude.count == 0)
    let status = await account.status()
    #expect(status == .signedIn(email: "user@example.com", planUsage: .pausedForUsageLimit))
  }

  @Test("AI-04: Claude を選んでいるときは、サインイン済みでも ChatGPT へは送らない")
  func claudeSelectionDoesNotUseChatGPT() async throws {
    var settings = Self.ready()
    settings.cloudRefinementProvider = .claude
    let chatGPT = PlanStreamingTransport()
    let claude = CountingTransport()
    let result = try await refine(
      pipeline(settings, account: Self.signedIn(), chatGPT: chatGPT, claude: claude))

    #expect(result.route == .cloud)
    #expect(chatGPT.count == 0)
    #expect(claude.count == 1)
  }
}
