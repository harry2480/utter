import Testing

@testable import UtterCore

struct ConsentStateTests {
  /// 同意対象のすべての部分集合。
  private static let allGrantedSets: [Set<ConsentScope>] = ConsentScope.allCases.reduce([[]]) {
    subsets, scope in
    subsets + subsets.map { $0.union([scope]) }
  }

  private static func state(granting scopes: Set<ConsentScope>) -> ConsentState {
    var state = ConsentState()
    for scope in scopes {
      state.grant(scope)
    }
    return state
  }

  @Test("AC-06: 同意対象は送信先・送信内容ごとに区別される")
  func scopesAreDistinct() {
    #expect(ConsentScope.allCases.count == 6)
    #expect(Set(ConsentScope.allCases).count == ConsentScope.allCases.count)
    #expect(Set(CloudTransmission.allCases).count == 5)
  }

  @Test("AC-06: 既定はすべて未同意で、どの送信も許可しない")
  func defaultDeniesEverything() {
    let state = ConsentState()
    for scope in ConsentScope.allCases {
      #expect(state.status(of: scope) == .notGranted)
    }
    for transmission in CloudTransmission.allCases {
      #expect(!state.allows(transmission))
    }
    for source in CloudAIProvider.allCases {
      for destination in CloudAIProvider.allCases {
        #expect(!state.allowsFallback(from: source, to: destination))
      }
    }
  }

  @Test("AC-06: 同意した送信だけを許可する（全組み合わせ）")
  func allowsOnlyGrantedTransmissions() {
    for granted in Self.allGrantedSets {
      let state = Self.state(granting: granted)
      for transmission in CloudTransmission.allCases {
        #expect(state.allows(transmission) == granted.contains(.transmission(transmission)))
      }
    }
  }

  @Test("AI-04: 自動フォールバックはその同意と切り替え先への同意がある場合だけ許可する（全組み合わせ）")
  func allowsFallbackOnlyWithBothConsents() {
    for granted in Self.allGrantedSets {
      let state = Self.state(granting: granted)
      for source in CloudAIProvider.allCases {
        for destination in CloudAIProvider.allCases {
          let expected =
            source != destination
            && granted.contains(.crossProviderFallback)
            && granted.contains(.transmission(.textRefinement(destination)))
          #expect(state.allowsFallback(from: source, to: destination) == expected)
        }
      }
    }
  }

  @Test("AI-04: 自動フォールバックは既定で無効")
  func fallbackIsDisabledByDefault() {
    var state = ConsentState()
    for provider in CloudAIProvider.allCases {
      state.grant(.transmission(.textRefinement(provider)))
    }
    #expect(!state.allowsFallback(from: .claude, to: .chatGPT))
    #expect(!state.allowsFallback(from: .chatGPT, to: .claude))
  }

  @Test("AC-12: 撤回するとすぐに送信不可になる", arguments: ConsentScope.allCases)
  func revokeDeniesImmediately(_ scope: ConsentScope) {
    var state = Self.state(granting: Set(ConsentScope.allCases))
    #expect(state.isGranted(scope))

    state.revoke(scope)

    #expect(state.status(of: scope) == .revoked)
    #expect(!state.isGranted(scope))
    if case .transmission(let transmission) = scope {
      #expect(!state.allows(transmission))
    }
    for other in ConsentScope.allCases where other != scope {
      #expect(state.isGranted(other))
    }
  }

  @Test("AC-12: 撤回後に送信不可となるフォールバックの判定")
  func revokingFallbackOrDestinationDeniesFallback() {
    var state = Self.state(granting: Set(ConsentScope.allCases))
    #expect(state.allowsFallback(from: .claude, to: .chatGPT))

    var withoutFallback = state
    withoutFallback.revoke(.crossProviderFallback)
    #expect(!withoutFallback.allowsFallback(from: .claude, to: .chatGPT))

    state.revoke(.transmission(.textRefinement(.chatGPT)))
    #expect(!state.allowsFallback(from: .claude, to: .chatGPT))
    #expect(state.allowsFallback(from: .chatGPT, to: .claude))
  }

  @Test("AC-12: 撤回後に再び同意すると送信可になる")
  func regrantAfterRevoke() {
    var state = ConsentState()
    state.grant(.transmission(.speechRecognition))
    state.revoke(.transmission(.speechRecognition))
    state.grant(.transmission(.speechRecognition))

    #expect(state.status(of: .transmission(.speechRecognition)) == .granted)
    #expect(state.allows(.speechRecognition))
  }

  @Test("AC-06: 未同意の対象を撤回しても未同意のまま", arguments: ConsentScope.allCases)
  func revokeWithoutGrantKeepsNotGranted(_ scope: ConsentScope) {
    var state = ConsentState()
    state.revoke(scope)
    #expect(state.status(of: scope) == .notGranted)
  }

  @Test("AC-06: AI 整形と Edit の選択テキストは別の同意として扱う")
  func refinementAndEditAreSeparate() {
    var state = ConsentState()
    state.grant(.transmission(.textRefinement(.claude)))

    #expect(state.allows(.textRefinement(.claude)))
    #expect(!state.allows(.editSelection(.claude)))
    #expect(!state.allows(.textRefinement(.chatGPT)))
    #expect(!state.allows(.speechRecognition))
  }
}
