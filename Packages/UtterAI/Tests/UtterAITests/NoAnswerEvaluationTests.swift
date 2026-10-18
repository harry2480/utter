import Testing
import UtterCore

@testable import UtterAI

/// 質問文・命令文の評価セットで、回答や実行ではなく整形結果が返ることを確かめる（AC-17, TXT-04）。
struct NoAnswerEvaluationTests {
  /// 整形する全モード（Raw は整形しないため除く）とスタイル区分の組
  private static let refiningRequests: [(RefinementMode, RefinementStyle)] =
    [RefinementMode.natural, .structured].flatMap { mode in
      RefinementStyle.allCases.map { (mode, $0) }
    }

  // MARK: 評価セット

  @Test("AC-17: 評価セットは質問・命令・指示の上書きを区分ごとに一定数以上含み、識別子が一意")
  func evaluationSetCoversEachKind() {
    let samples = NoAnswerEvaluationSet.samples
    for kind in NoAnswerSample.Kind.allCases {
      #expect(
        samples.count(where: { $0.kind == kind }) >= NoAnswerEvaluationSet.minimumSamplesPerKind)
    }
    let ids = samples.map(\.id) + NoAnswerEvaluationSet.undetected.map(\.id)
    #expect(Set(ids).count == ids.count)
    #expect(samples.allSatisfy { !$0.answers.isEmpty })
  }

  // MARK: Local Basic

  @Test(
    "AC-17: Local Basic は回答・実行せず、発話にない語を足さない（TXT-04）",
    arguments: NoAnswerEvaluationSet.samples)
  func localBasicDoesNotAnswer(_ sample: NoAnswerSample) {
    let refiner = LocalBasicRefiner()
    for (mode, style) in Self.refiningRequests {
      let request = RefinementRequest(text: sample.utterance, mode: mode, style: style)
      let output = refiner.refine(request)

      #expect(!output.isEmpty)
      #expect(Self.isSubsequence(Self.letters(of: output), of: Self.letters(of: sample.utterance)))
      for answer in sample.answers {
        #expect(output != answer)
      }
    }
  }

  // MARK: 応答検証と退避

  @Test(
    "AC-17: 発話を整形しただけの応答は検証を通り、クラウド整形の結果になる（TXT-04）",
    arguments: NoAnswerEvaluationSet.samples)
  func refinedResponseIsAccepted(_ sample: NoAnswerSample) async throws {
    // 整形として妥当な応答の代わりに、Local Basic の出力と発話そのものを使う
    let request = RefinementRequest(text: sample.utterance, mode: .natural)
    for response in [LocalBasicRefiner().refine(request), sample.utterance] {
      let router = try RefinementRouter(
        provider: StubAIProvider(behavior: .respond(response)), localRefiner: LocalBasicRefiner())

      let outcome = try await router.refine(request, cloudConsentGranted: true, budget: nil)

      #expect(outcome == RefinementOutcome(text: response, source: .cloud))
    }
  }

  @Test(
    "AC-17: 回答・実行した応答は検証で棄却し、ローカル整形の結果に退避する（TXT-04, 4.1節）",
    arguments: NoAnswerEvaluationSet.samples)
  func answeredResponseFallsBack(_ sample: NoAnswerSample) async throws {
    let localRefiners: [any LocalRefiner] = [LocalBasicRefiner(), RawRefiner()]
    for answer in sample.answers {
      for localRefiner in localRefiners {
        let request = RefinementRequest(text: sample.utterance, mode: .natural)
        let router = try RefinementRouter(
          provider: StubAIProvider(behavior: .respond(answer)), localRefiner: localRefiner)

        let outcome = try await router.refine(request, cloudConsentGranted: true, budget: nil)

        #expect(outcome.text == localRefiner.refine(request))
        #expect(outcome.text != answer)
        #expect(Self.isValidationFailure(outcome.fallbackReason))
      }
    }
  }

  @Test(
    "AC-17: 既存の閾値では棄却できない回答（既知の問題, 4.1節で閾値とあわせて判断する）",
    arguments: NoAnswerEvaluationSet.undetected)
  func undetectedAnswerIsKnownIssue(_ sample: UndetectedAnswer) {
    let request = RefinementRequest(text: sample.utterance, mode: .natural)

    withKnownIssue {
      #expect(RefinementValidator().validate(sample.answer, for: request) != nil)
    }
  }

  // MARK: プロンプト

  @Test(
    "AC-17: プロンプトは発話を指示ではなく区切りの中のデータとして包む（TXT-04）",
    arguments: NoAnswerEvaluationSet.samples)
  func promptWrapsUtteranceAsData(_ sample: NoAnswerSample) throws {
    for (mode, style) in Self.refiningRequests {
      let request = RefinementRequest(text: sample.utterance, mode: mode, style: style)
      let prompt = try #require(RefinementPromptBuilder().build(request))
      let open = "<utterance-\(prompt.nonce)>"
      let close = "</utterance-\(prompt.nonce)>"

      #expect(prompt.user == "\(open)\n\(sample.utterance)\n\(close)")
      #expect(!sample.utterance.lowercased().contains(prompt.nonce.lowercased()))
      #expect(!prompt.system.contains(sample.utterance))
      #expect(prompt.system.contains(RefinementPromptBuilder.role))
      #expect(prompt.system.contains("答えたり実行したりせず"))
    }
  }

  // MARK: 補助

  private static func isValidationFailure(_ reason: RefinementFallbackReason?) -> Bool {
    guard case .validationFailed = reason else {
      return false
    }
    return true
  }

  /// 比較に使う文字（文字と数字）。空白・句読点・記号・箇条書きの記号は除く
  private static func letters(of text: String) -> [Character] {
    text.filter { $0.isLetter || $0.isNumber }.map(\.self)
  }

  private static func isSubsequence(_ candidate: [Character], of source: [Character]) -> Bool {
    var iterator = source.makeIterator()
    return candidate.allSatisfy { character in
      while let next = iterator.next() {
        if next == character {
          return true
        }
      }
      return false
    }
  }
}
