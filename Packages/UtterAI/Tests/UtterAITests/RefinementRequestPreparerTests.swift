import Testing
import UtterCore
import UtterText

@testable import UtterAI

struct RefinementRequestPreparerTests {
  private let slackBundleID = "com.tinyspeck.slackmacgap"

  private func makeDictionary() throws -> UserDictionary {
    try UserDictionary(
      terms: [DictionaryTerm("SwiftUI"), DictionaryTerm("Xcode"), DictionaryTerm("SwiftUI")],
      rules: [ReplacementRule(pattern: "すいふとゆーあい", replacement: "SwiftUI")])
  }

  private func makePreparer(
    overrides: [String: RefinementStyle] = [:]
  ) throws -> RefinementRequestPreparer {
    RefinementRequestPreparer(
      dictionary: try makeDictionary(), styleResolver: AppStyleResolver(overrides: overrides))
  }

  @Test(
    "TXT-03, AC-07: 置換後の本文と辞書語がプロバイダーに届く",
    arguments: [RefinementMode.natural, .structured])
  func providerReceivesReplacedTextAndTerms(_ mode: RefinementMode) async throws {
    let request = try makePreparer().prepare(
      transcript: "えーとすいふとゆーあいで作ります", mode: mode, frontmostBundleID: slackBundleID)
    let stub = StubAIProvider(behavior: .echo)
    let router = try RefinementRouter(provider: stub)

    _ = try await router.refine(
      request, consent: .refinementGranted(), budget: nil, sensitivity: { .allowedInput })

    let received = try #require(await stub.receivedRequests.first)
    #expect(received.text == "えーとSwiftUIで作ります")
    #expect(received.mode == mode)
    #expect(received.style == .concise)
    #expect(received.dictionaryTerms == ["SwiftUI", "Xcode"])
  }

  @Test("CTX-02, AC-07: 利用者のアプリ別上書きが既定の対応表に優先する")
  func overrideTakesPrecedence() throws {
    let preparer = try makePreparer(overrides: [slackBundleID: .polite])

    let request = preparer.prepare(
      transcript: "了解です", mode: .natural, frontmostBundleID: slackBundleID)

    #expect(request.style == .polite)
  }

  @Test("CTX-01: 前面アプリを特定できなければ standard", arguments: [nil, "", "com.example.unknown"])
  func unknownAppIsStandard(_ bundleID: String?) throws {
    let request = try makePreparer().prepare(
      transcript: "了解です", mode: .natural, frontmostBundleID: bundleID)

    #expect(request.style == .standard)
  }

  @Test("CTX-03: bundle ID はリクエストに含めず、スタイル区分だけを渡す")
  func bundleIDIsNotIncluded() throws {
    let request = try makePreparer().prepare(
      transcript: "了解です", mode: .structured, frontmostBundleID: slackBundleID)

    // 格納項目が本文・モード・スタイル・辞書語だけであることは RefinementRequestTests のサイズ検査で確認している。
    #expect(
      request
        == RefinementRequest(
          text: "了解です", mode: .structured, style: .concise, dictionaryTerms: ["SwiftUI", "Xcode"]))
  }

  @Test("TXT-01: Raw モードは置換ルールを適用せず STT 結果をそのまま使う")
  func rawModeKeepsTranscript() async throws {
    let request = try makePreparer().prepare(
      transcript: "えーとすいふとゆーあいで作ります", mode: .raw, frontmostBundleID: slackBundleID)
    let stub = StubAIProvider(behavior: .echo)
    let router = try RefinementRouter(provider: stub)

    let outcome = try await router.refine(
      request, consent: .refinementGranted(), budget: nil, sensitivity: { .allowedInput })

    #expect(request.text == "えーとすいふとゆーあいで作ります")
    #expect(outcome == RefinementOutcome(text: "えーとすいふとゆーあいで作ります", source: .raw))
    #expect(await stub.callCount == 0)
  }

  @Test("TXT-03: ローカルへの退避でも置換後の本文を使う")
  func localFallbackUsesReplacedText() async throws {
    let request = try makePreparer().prepare(
      transcript: "えーとすいふとゆーあいで作ります", mode: .natural, frontmostBundleID: nil)
    let stub = StubAIProvider(behavior: .fail(.networkUnavailable))
    let router = try RefinementRouter(provider: stub, localRefiner: LocalBasicRefiner())

    let outcome = try await router.refine(
      request, consent: .refinementGranted(), budget: nil, sensitivity: { .allowedInput })

    #expect(
      outcome
        == RefinementOutcome(
          text: "SwiftUIで作ります。",
          source: .localFallback(.providerFailed(.networkUnavailable))))
  }

  @Test("TXT-03: 同意がなく送信しないときも、退避の結果に置換が効く")
  func fallbackWithoutConsentUsesReplacedText() async throws {
    let request = try makePreparer().prepare(
      transcript: "すいふとゆーあいで作ります", mode: .natural, frontmostBundleID: nil)
    let stub = StubAIProvider(behavior: .echo)
    let router = try RefinementRouter(provider: stub, localRefiner: LocalBasicRefiner())

    let outcome = try await router.refine(
      request, consent: ConsentState(), budget: nil, sensitivity: { .allowedInput })

    #expect(await stub.callCount == 0)
    #expect(outcome.text == "SwiftUIで作ります。")
    #expect(outcome.source == .localFallback(.consentNotGranted))
  }
}
