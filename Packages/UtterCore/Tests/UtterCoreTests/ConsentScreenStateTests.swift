import Testing

@testable import UtterCore

struct ConsentScreenStateTests {
  @Test("AC-06: 既定はすべて未同意で、送信する機能がある対象（Claude への整形）の行を表示する")
  func defaultsToNotGranted() {
    let screen = ConsentScreenState()

    #expect(screen.rows.map(\.scope) == [.transmission(.textRefinement(.claude))])
    #expect(screen.rows.allSatisfy { $0.status == .notGranted && !$0.isGranted })
    #expect(screen.rows.allSatisfy { $0.statusLabel == "未同意" })
    #expect(CloudTransmission.allCases.allSatisfy { !screen.consent.allows($0) })
  }

  @Test("AC-06: 行ごとに同意すると、その対象だけが同意済みになる")
  func grantsOnlyTheScope() {
    var screen = ConsentScreenState()

    screen.setGranted(true, for: .transmission(.textRefinement(.claude)))

    #expect(screen.consent.allows(.textRefinement(.claude)))
    #expect(!screen.consent.allows(.textRefinement(.chatGPT)))
    #expect(!screen.consent.isGranted(.crossProviderFallback))
    #expect(screen.rows.map(\.statusLabel) == ["同意済み"])
  }

  @Test("AC-06: 撤回すると次の判定から送信不可になり、撤回済みと表示する")
  func revokeTakesEffectImmediately() {
    var screen = ConsentScreenState()
    screen.setGranted(true, for: .transmission(.textRefinement(.claude)))

    screen.setGranted(false, for: .transmission(.textRefinement(.claude)))

    #expect(!screen.consent.allows(.textRefinement(.claude)))
    #expect(screen.rows[0].status == .revoked)
    #expect(screen.rows[0].statusLabel == "撤回済み")
    #expect(!screen.rows[0].isGranted)
  }

  @Test("AC-06: 同意していない対象の撤回は未同意のまま")
  func revokingNotGrantedKeepsNotGranted() {
    var screen = ConsentScreenState()

    screen.setGranted(false, for: .crossProviderFallback)

    #expect(screen.consent == ConsentState())
  }

  @Test("AI-04: 自動切り替えへの同意だけでは切り替えず、両方の整形の同意が要る")
  func fallbackNeedsBothDestinations() {
    var screen = ConsentScreenState()
    screen.setGranted(true, for: .crossProviderFallback)
    screen.setGranted(true, for: .transmission(.textRefinement(.claude)))
    #expect(!screen.consent.allowsFallback(from: .claude, to: .chatGPT))

    screen.setGranted(true, for: .transmission(.textRefinement(.chatGPT)))
    #expect(screen.consent.allowsFallback(from: .claude, to: .chatGPT))

    screen.setGranted(false, for: .transmission(.textRefinement(.chatGPT)))
    #expect(!screen.consent.allowsFallback(from: .claude, to: .chatGPT))
  }

  @Test(
    "AC-06: 送信機能のない対象に同意済みの状態を読んだら、撤回できるよう行を表示する",
    arguments: [
      ConsentScope.transmission(.textRefinement(.chatGPT)), .crossProviderFallback,
      .transmission(.speechRecognition), .transmission(.editSelection(.claude)),
    ])
  func showsGrantedHiddenScopeForRevocation(_ scope: ConsentScope) {
    var consent = ConsentState()
    consent.grant(scope)
    var screen = ConsentScreenState(consent: consent)
    #expect(screen.rows.last?.scope == scope)
    #expect(screen.rows.count == ConsentScreenState.presentedScopes.count + 1)

    screen.setGranted(false, for: scope)

    #expect(!screen.consent.isGranted(scope))
    #expect(screen.rows.count == ConsentScreenState.presentedScopes.count)
  }
}
