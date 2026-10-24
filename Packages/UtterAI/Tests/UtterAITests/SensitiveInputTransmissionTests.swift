import Synchronization
import Testing
import UtterCore

@testable import UtterAI

/// 送信部を監視し、機密入力の入力先では整形を外部へ送信しないことを確かめる（7章, AC-12）。
///
/// 実際の `ClaudeProvider` を `RefinementRouter` につなぎ、HTTP の送信部だけを記録用に差し替える。
struct SensitiveInputTransmissionTests {
  private static let editor = "com.example.editor"
  private static let policy = SensitiveInputPolicy(
    sensitiveApps: ["com.example.vault"], excludedApps: ["com.example.chat"])

  // swift-format-ignore: NeverUseForceTry
  private let configuration = try! ClaudeProvider.Configuration(model: "test-model", maxTokens: 512)

  private func router(_ transport: ClaudeProviderTests.StubTransport) throws -> RefinementRouter {
    try RefinementRouter(
      provider: ClaudeProvider(
        apiKey: "sk-test-secret", configuration: configuration, transport: transport),
      localRefiner: LocalBasicRefiner())
  }

  private func request(_ mode: RefinementMode) -> RefinementRequest {
    RefinementRequest(text: "えーと明日の会議は10時からです", mode: mode, style: .polite)
  }

  private func transport() -> ClaudeProviderTests.StubTransport {
    ClaudeProviderTests.StubTransport(
      .response(status: 200, body: ClaudeProviderTests.successBody))
  }

  @Test(
    "AC-12: 機密入力・判定できない入力先では、整形の同意があっても送信が0件でローカル整形へ退避する",
    arguments: [
      SensitiveInputContext(secureField: .on, secureEventInput: .off, app: editor),
      SensitiveInputContext(secureField: .off, secureEventInput: .on, app: editor),
      SensitiveInputContext(secureField: .unknown, secureEventInput: .off, app: editor),
      SensitiveInputContext(secureField: .off, secureEventInput: .unknown, app: editor),
      SensitiveInputContext(secureField: .off, secureEventInput: .off, app: nil),
      SensitiveInputContext(secureField: .off, secureEventInput: .off, app: "com.example.vault"),
      SensitiveInputContext(secureField: .off, secureEventInput: .off, app: "com.example.chat"),
    ])
  func doesNotSendSensitiveInput(_ context: SensitiveInputContext) async throws {
    let decision = Self.policy.decide(context)
    for mode in [RefinementMode.natural, .structured] {
      let transport = transport()
      let request = request(mode)

      let outcome = try await router(transport).refine(
        request, consent: .refinementGranted(), budget: nil, sensitivity: { decision })

      #expect(transport.requests.withLock { $0.isEmpty })
      #expect(
        outcome
          == RefinementOutcome(
            text: LocalBasicRefiner().refine(request),
            source: .localFallback(.sensitiveInputSuppressed)))
    }
  }

  @Test("AC-12: 機密入力に当たらない入力先では、従来どおり送信する")
  func sendsWhenNotSensitive() async throws {
    let transport = transport()
    let decision = Self.policy.decide(
      SensitiveInputContext(secureField: .off, secureEventInput: .off, app: Self.editor))

    let outcome = try await router(transport).refine(
      request(.natural), consent: .refinementGranted(), budget: nil, sensitivity: { decision })

    #expect(transport.requests.withLock { $0.map(\.url?.host) } == ["api.anthropic.com"])
    #expect(outcome.source == .cloud)
  }

  @Test("AC-12: Raw モードは機密入力の判定をせず、従来どおり送信せずに STT テキストを返す")
  func rawIsUnaffected() async throws {
    let transport = transport()
    let calls = Mutex(0)

    let outcome = try await router(transport).refine(
      request(.raw), consent: .refinementGranted(), budget: nil,
      sensitivity: {
        calls.withLock { $0 += 1 }
        return .secureFieldInput
      })

    #expect(calls.withLock { $0 } == 0)
    #expect(transport.requests.withLock { $0.isEmpty })
    #expect(outcome == RefinementOutcome(text: request(.raw).text, source: .raw))
  }

  @Test("AC-06, AC-12: 同意がなく機密入力でもあるときは、同意がないことを退避の理由にする")
  func consentIsCheckedBeforeSensitivity() async throws {
    let transport = transport()

    let outcome = try await router(transport).refine(
      request(.natural), consent: ConsentState(), budget: nil,
      sensitivity: { .secureFieldInput })

    #expect(transport.requests.withLock { $0.isEmpty })
    #expect(outcome.fallbackReason == .consentNotGranted)
  }

  @Test("AC-12: 予算の確認がない送信先でも、判定はプロバイダーを呼ぶ前に1回だけ行う")
  func evaluatesOnceWithoutBudget() async throws {
    let calls = Mutex(0)
    let stub = StubAIProvider(behavior: .echo)
    let router = try RefinementRouter(provider: stub)

    let outcome = try await router.refine(
      request(.natural), consent: .refinementGranted(), budget: nil,
      sensitivity: {
        calls.withLock { $0 += 1 }
        return .allowedInput
      })

    #expect(outcome.source == .cloud)
    #expect(calls.withLock { $0 } == 1)
    #expect(await stub.callCount == 1)
  }
}
