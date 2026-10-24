import Foundation
import Testing
import UtterCore

@testable import UtterAI

/// 同意の画面で操作した後の同意状態を `RefinementRouter` に渡し、外部への送信の有無を確かめる（AC-06）。
///
/// 同意状態は JSON で往復させた値を使い、実際の `ClaudeProvider` の HTTP 送信部だけを記録用に差し替える。
/// 同意の組み合わせの網羅は `ConsentTransmissionTests`、設定への保存と復元は UtterPersistence の
/// `ConsentSettingsControllerTests` が受け持つ。
struct ConsentScreenTransmissionTests {
  // swift-format-ignore: NeverUseForceTry
  private let configuration = try! ClaudeProvider.Configuration(model: "test-model", maxTokens: 512)

  private let request = RefinementRequest(
    text: "えーと明日の会議は10時からです", mode: .natural, style: .polite)

  private func router(_ transport: ClaudeProviderTests.StubTransport) throws -> RefinementRouter {
    try RefinementRouter(
      provider: ClaudeProvider(
        apiKey: "sk-test-secret", configuration: configuration, transport: transport))
  }

  /// JSON で往復させた同意状態
  private func restored(_ screen: ConsentScreenState) throws -> ConsentState {
    try JSONDecoder().decode(ConsentState.self, from: JSONEncoder().encode(screen.consent))
  }

  private func sentHosts(
    with consent: ConsentState
  ) async throws -> (hosts: [String?], outcome: RefinementOutcome) {
    let transport = ClaudeProviderTests.StubTransport(
      .response(status: 200, body: ClaudeProviderTests.successBody))
    let outcome = try await router(transport).refine(request, consent: consent, budget: nil)
    return (transport.requests.withLock { $0.map(\.url?.host) }, outcome)
  }

  @Test("AC-06: 画面で同意すると送信し、撤回した直後の整形から外部送信が0件になる")
  func revokeOnScreenStopsSending() async throws {
    var screen = ConsentScreenState()
    screen.setGranted(true, for: .transmission(.textRefinement(.claude)))
    let granted = try await sentHosts(with: restored(screen))
    #expect(granted.hosts == ["api.anthropic.com"])

    screen.setGranted(false, for: .transmission(.textRefinement(.claude)))
    let revoked = try await sentHosts(with: restored(screen))

    #expect(revoked.hosts.isEmpty)
    #expect(revoked.outcome.source == .localFallback(.consentNotGranted))
  }

  @Test("AC-06: 画面で Claude への整形以外のすべてに同意しても Claude へは送信しない")
  func otherScopesDoNotAllowClaude() async throws {
    var screen = ConsentScreenState()
    for scope in ConsentScope.allCases where scope != .transmission(.textRefinement(.claude)) {
      screen.setGranted(true, for: scope)
    }

    let (hosts, _) = try await sentHosts(with: restored(screen))

    #expect(hosts.isEmpty)
  }
}
