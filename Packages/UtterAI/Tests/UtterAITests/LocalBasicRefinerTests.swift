import Testing

@testable import UtterAI

struct LocalBasicRefinerTests {
  private let refiner = LocalBasicRefiner()

  @Test("AI-03: Raw は STT テキストをそのまま返す")
  func rawReturnsText() {
    let request = RefinementRequest(text: "えーと  明日", mode: .raw)

    #expect(refiner.refine(request) == "えーと  明日")
  }

  @Test("AI-03: Natural はフィラーを除いて句読点を補う")
  func natural() {
    let request = RefinementRequest(text: "えーと明日の会議は10時からです", mode: .natural)

    #expect(refiner.refine(request) == "明日の会議は10時からです。")
  }

  @Test("AI-03: Structured は列挙を箇条書きにする")
  func structured() {
    let request = RefinementRequest(text: "まず開きます。次に閉じます", mode: .structured)

    #expect(refiner.refine(request) == "- まず開きます。\n- 次に閉じます。")
  }

  @Test("AI-03: チャットとターミナルでは文末の「。」を補わない", arguments: [RefinementStyle.concise, .command])
  func noSentenceEndForChatAndTerminal(_ style: RefinementStyle) {
    let request = RefinementRequest(text: "えー了解です", mode: .natural, style: style)

    #expect(refiner.refine(request) == "了解です")
  }

  @Test("AI-03: ターミナルでは Structured でも箇条書きにしない")
  func terminalStructuredIsNatural() {
    let request = RefinementRequest(text: "まず開きます。次に閉じます", mode: .structured, style: .command)

    #expect(refiner.refine(request) == "まず開きます。次に閉じます")
  }

  @Test("AI-03: 辞書語を保護する")
  func protectsDictionaryTerms() {
    let request = RefinementRequest(
      text: "えー Go  と  Rust", mode: .natural, dictionaryTerms: ["Go"])

    #expect(refiner.refine(request) == "Go と Rust")
  }

  @Test("AC-16: クラウド整形の退避先として使える")
  func worksAsFallback() async throws {
    let router = try RefinementRouter(
      provider: StubAIProvider(behavior: .fail(.timeout)), localRefiner: refiner)
    let request = RefinementRequest(text: "えーと了解です", mode: .natural)

    let outcome = try await router.refine(request, cloudConsentGranted: true)

    #expect(outcome.text == "了解です。")
    #expect(outcome.source == .localFallback(.providerFailed(.timeout)))
  }
}
