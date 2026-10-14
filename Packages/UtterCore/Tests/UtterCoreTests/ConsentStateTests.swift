import Testing

@testable import UtterCore

struct ConsentStateTests {
  /// 各同意対象を未同意・同意・撤回済みのいずれかにした、すべての組み合わせ（3^6 通り）。
  static let allStatusCombinations: [[ConsentScope: ConsentStatus]] = ConsentScope.allCases
    .reduce([[:]]) { combinations, scope in
      combinations.flatMap { combination in
        [ConsentStatus.notGranted, .granted, .revoked].map { status in
          combination.merging([scope: status]) { $1 }
        }
      }
    }

  /// 送信元・送信先プロバイダーのすべての組み合わせ。
  static let providerPairs: [(CloudAIProviderKind, CloudAIProviderKind)] =
    CloudAIProviderKind.allCases.flatMap { source in
      CloudAIProviderKind.allCases.map { (source, $0) }
    }

  /// 操作の履歴から、指定した状態の `ConsentState` を作る。
  private static func state(_ statuses: [ConsentScope: ConsentStatus]) -> ConsentState {
    var state = ConsentState()
    for (scope, status) in statuses {
      switch status {
      case .notGranted:
        break
      case .granted:
        state.grant(scope)
      case .revoked:
        state.grant(scope)
        state.revoke(scope)
      }
    }
    return state
  }

  @Test("AC-06: 同意対象は送信先・送信内容ごとに区別される")
  func scopesAreDistinct() {
    // ケースの追加漏れを検知する: (Claude, ChatGPT) × (整形, Edit) + STT = 5、それにフォールバックを加えて 6。
    #expect(Set(CloudTransmission.allCases).count == 5)
    #expect(Set(ConsentScope.allCases).count == 6)
    #expect(ConsentScope.allCases.count == 6)
    #expect(Self.allStatusCombinations.count == 729)
  }

  @Test("AC-06: 既定は未同意", arguments: ConsentScope.allCases)
  func defaultIsNotGranted(_ scope: ConsentScope) {
    #expect(ConsentState().status(of: scope) == .notGranted)
  }

  @Test("AC-06: 既定ではどの送信も許可しない", arguments: CloudTransmission.allCases)
  func defaultDeniesTransmission(_ transmission: CloudTransmission) {
    #expect(!ConsentState().allows(transmission))
  }

  @Test("AI-04: クラウド間の自動フォールバックは既定で無効")
  func defaultDeniesFallback() {
    for (source, destination) in Self.providerPairs {
      #expect(!ConsentState().allowsFallback(from: source, to: destination))
    }
  }

  @Test("AI-04: 両プロバイダーに同意していても、フォールバックの同意がなければ切り替えない")
  func fallbackNeedsItsOwnConsent() {
    var state = ConsentState()
    for provider in CloudAIProviderKind.allCases {
      state.grant(.transmission(.textRefinement(provider)))
    }
    #expect(!state.allowsFallback(from: .claude, to: .chatGPT))
    #expect(!state.allowsFallback(from: .chatGPT, to: .claude))
  }

  @Test("AC-06: 同意している送信だけを許可する（未同意・撤回済みの全組み合わせ）", arguments: allStatusCombinations)
  func allowsOnlyGrantedTransmissions(_ statuses: [ConsentScope: ConsentStatus]) {
    let state = Self.state(statuses)
    for transmission in CloudTransmission.allCases {
      let expected = statuses[.transmission(transmission)] == .granted
      #expect(state.allows(transmission) == expected)
    }
  }

  @Test(
    "AI-04: 自動フォールバックはその同意と切り替え元・先への同意がある場合だけ許可する（全組み合わせ）",
    arguments: allStatusCombinations)
  func allowsFallbackOnlyWithAllConsents(_ statuses: [ConsentScope: ConsentStatus]) {
    let state = Self.state(statuses)
    for (source, destination) in Self.providerPairs {
      let expected =
        source != destination
        && statuses[.crossProviderFallback] == .granted
        && statuses[.transmission(.textRefinement(source))] == .granted
        && statuses[.transmission(.textRefinement(destination))] == .granted
      #expect(state.allowsFallback(from: source, to: destination) == expected)
    }
  }

  @Test("AC-12: 撤回するとすぐに送信不可になり、他の同意は変わらない", arguments: ConsentScope.allCases)
  func revokeDeniesImmediately(_ scope: ConsentScope) {
    var state = Self.state(
      Dictionary(uniqueKeysWithValues: ConsentScope.allCases.map { ($0, .granted) }))
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

  @Test("AC-12: 撤回後に再び同意すると同意済みに戻る", arguments: ConsentScope.allCases)
  func regrantAfterRevoke(_ scope: ConsentScope) {
    var state = ConsentState()
    state.grant(scope)
    state.revoke(scope)
    state.grant(scope)

    #expect(state.status(of: scope) == .granted)
  }

  @Test("AC-12: 撤回済みの対象を再び撤回しても撤回済みのまま", arguments: ConsentScope.allCases)
  func revokeTwiceKeepsRevoked(_ scope: ConsentScope) {
    var state = ConsentState()
    state.grant(scope)
    state.revoke(scope)
    state.revoke(scope)

    #expect(state.status(of: scope) == .revoked)
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
