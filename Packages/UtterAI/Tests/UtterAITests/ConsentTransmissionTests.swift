import Testing
import UtterCore

@testable import UtterAI

/// 送信部を監視し、同意の状態ごとに外部への送信の有無を確かめる（AC-06）。
///
/// 実際の `ClaudeProvider` を `RefinementRouter` につなぎ、HTTP の送信部だけを記録用に差し替える。
struct ConsentTransmissionTests {
  /// すべての同意対象について「未同意・同意・撤回」を組み合わせた状態（3^6 通り）
  static let allConsentStates: [ConsentState] = ConsentScope.allCases
    .reduce([ConsentState()]) { states, scope in
      states.flatMap { state in
        var granted = state
        granted.grant(scope)
        var revoked = granted
        revoked.revoke(scope)
        return [state, granted, revoked]
      }
    }

  // swift-format-ignore: NeverUseForceTry
  private let configuration = try! ClaudeProvider.Configuration(model: "test-model", maxTokens: 512)

  private func router(_ transport: ClaudeProviderTests.StubTransport) throws -> RefinementRouter {
    try RefinementRouter(
      provider: ClaudeProvider(
        apiKey: "sk-test-secret", configuration: configuration, transport: transport))
  }

  private func request(_ mode: RefinementMode) -> RefinementRequest {
    RefinementRequest(text: "えーと明日の会議は10時からです", mode: mode, style: .polite)
  }

  @Test("AC-06: 同意の組み合わせは全対象の未同意・同意・撤回を網羅する")
  func coversAllConsentStates() {
    #expect(Self.allConsentStates.count == 729)
    #expect(Set(Self.allConsentStates).count == 729)
  }

  @Test(
    "AC-06: Claude への整形の同意がある状態でだけ送信し、それ以外の同意の状態では送信が0件",
    arguments: [RefinementMode.natural, .structured])
  func sendsOnlyWithRefinementConsent(_ mode: RefinementMode) async throws {
    var sentStates = 0
    for consent in Self.allConsentStates {
      let transport = ClaudeProviderTests.StubTransport(
        .response(status: 200, body: ClaudeProviderTests.successBody))

      let outcome = try await router(transport).refine(
        request(mode), consent: { consent }, budget: nil, sensitivity: { .allowedInput })

      let sent = transport.requests.withLock { $0.map(\.url?.host) }
      // 期待値は判定の対象（ConsentState.allows）を使わず、同意の状態から直接求める
      if consent.status(of: .transmission(.textRefinement(.claude))) == .granted {
        #expect(sent == ["api.anthropic.com"])
        #expect(outcome.source == .cloud)
        sentStates += 1
      } else {
        #expect(sent.isEmpty)
        #expect(outcome.source == .localFallback(.consentNotGranted))
      }
    }
    // 送信先への整形の同意が「同意」の状態は 3^5 通り
    #expect(sentStates == 243)
  }

  @Test("AC-06: Raw モードはどの同意の状態でも送信が0件")
  func rawNeverSends() async throws {
    for consent in Self.allConsentStates {
      let transport = ClaudeProviderTests.StubTransport(
        .response(status: 200, body: ClaudeProviderTests.successBody))

      let outcome = try await router(transport).refine(
        request(.raw), consent: { consent }, budget: nil, sensitivity: { .allowedInput })

      #expect(transport.requests.withLock { $0.isEmpty })
      #expect(outcome.source == .raw)
    }
  }

  @Test("AC-06: 送信先への整形の同意があれば、Claude 以外の送信先にも送信する")
  func sendsToOtherDestinationWithItsConsent() async throws {
    let chatGPT = StubAIProvider(behavior: .echo, destination: .chatGPT)
    let router = try RefinementRouter(provider: chatGPT)

    let outcome = try await router.refine(
      request(.natural), consent: { .refinementGranted(.chatGPT) }, budget: nil,
      sensitivity: { .allowedInput })

    #expect(await chatGPT.callCount == 1)
    #expect(outcome.source == .cloud)
  }

  @Test(
    "AC-06: Edit の選択テキスト・音声・自動切り替えへの同意では整形の送信をしない",
    arguments: [
      ConsentScope.transmission(.editSelection(.chatGPT)), .transmission(.speechRecognition),
      .crossProviderFallback,
    ])
  func otherScopeConsentDoesNotAllowSending(_ scope: ConsentScope) async throws {
    let chatGPT = StubAIProvider(behavior: .echo, destination: .chatGPT)
    let router = try RefinementRouter(provider: chatGPT)
    var consent = ConsentState()
    consent.grant(scope)

    let outcome = try await router.refine(
      request(.natural), consent: { consent }, budget: nil, sensitivity: { .allowedInput })

    #expect(await chatGPT.callCount == 0)
    #expect(outcome.source == .localFallback(.consentNotGranted))
  }

  @Test("AC-06: 別の送信先への整形の同意では送信しない")
  func otherDestinationConsentDoesNotAllowSending() async throws {
    let chatGPT = StubAIProvider(behavior: .echo, destination: .chatGPT)
    let router = try RefinementRouter(provider: chatGPT)

    let outcome = try await router.refine(
      request(.natural), consent: { .refinementGranted(.claude) }, budget: nil,
      sensitivity: { .allowedInput })

    #expect(await chatGPT.callCount == 0)
    #expect(outcome.source == .localFallback(.consentNotGranted))
  }
}
