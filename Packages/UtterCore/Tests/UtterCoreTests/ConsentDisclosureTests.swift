import Testing

@testable import UtterCore

struct ConsentDisclosureTests {
  @Test("CTX-03: どの同意対象にも、ウィンドウタイトル・既存本文・URL を送らないことを示す", arguments: ConsentScope.allCases)
  func listsContextNotSent(_ scope: ConsentScope) {
    let disclosure = ConsentDisclosure(scope: scope)

    for item in ["ウィンドウタイトル", "入力欄の既存本文", "URL"] {
      #expect(disclosure.notSent.contains(item))
    }
    #expect(!disclosure.title.isEmpty)
    #expect(!disclosure.content.isEmpty)
    #expect(!disclosure.destination.isEmpty)
  }

  @Test("AC-06, AI-04: 送信先ごとに送信先の事業者を示す")
  func namesDestinationPerProvider() {
    #expect(
      ConsentDisclosure(scope: .transmission(.textRefinement(.claude))).destination
        == "Anthropic（Claude API）")
    #expect(
      ConsentDisclosure(scope: .transmission(.textRefinement(.chatGPT))).destination
        == "OpenAI")
    #expect(
      Set(ConsentScope.allCases.map(ConsentDisclosure.init(scope:))).count
        == ConsentScope.allCases.count)
  }

  @Test("7章, CTX-03: 整形の説明は送る文脈をスタイル区分と辞書語に限り、音声を送らないことを示す")
  func refinementSendsOnlyStyleAndTerms() {
    let disclosure = ConsentDisclosure(scope: .transmission(.textRefinement(.claude)))

    #expect(disclosure.content.contains("スタイル区分"))
    #expect(disclosure.content.contains("辞書語"))
    #expect(disclosure.notSent.contains("音声"))
  }

  @Test("AC-06, #188: 音声の送信の説明は、送るのが録音した音声だけで、送信先が OpenAI であることを示す")
  func speechRecognitionNamesDestination() {
    let disclosure = ConsentDisclosure(scope: .transmission(.speechRecognition))

    #expect(disclosure.content == "録音した音声")
    #expect(disclosure.destination == "OpenAI（音声認識 API）")
    #expect(disclosure.notSent.contains("辞書語"))
  }

  @Test("AC-06: 文言は同意対象だけで決まり、同意の状態によって変わらない")
  func disclosureDependsOnlyOnScope() {
    var consent = ConsentState()
    for scope in ConsentScope.allCases { consent.grant(scope) }

    for row in ConsentScreenState(consent: consent).rows {
      #expect(row.disclosure == ConsentDisclosure(scope: row.scope))
    }
  }
}
