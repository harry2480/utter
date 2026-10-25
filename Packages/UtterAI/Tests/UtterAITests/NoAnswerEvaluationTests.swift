import Testing
import UtterCore

@testable import UtterAI

/// 質問文・命令文の評価セットで、回答や実行ではなく整形結果が返ることを確かめる（AC-17, TXT-04）。
///
/// 失敗時の表示に発話や応答の本文を出さないよう、本文の比較は真偽値か、本文を伏せる `RefinementOutcome` で行う。
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
    #expect(samples.allSatisfy { !$0.answers.isEmpty && !$0.refinedExamples.isEmpty })
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

      let addsNothing = Self.isSubsequence(
        Self.letters(of: output), of: Self.letters(of: sample.utterance))
      #expect(addsNothing, "\(mode), \(style)")
    }
  }

  // MARK: 応答検証と退避

  @Test(
    "AC-17: 整形として妥当な応答は検証を通り、クラウド整形の結果になる（TXT-04）",
    arguments: NoAnswerEvaluationSet.samples)
  func refinedExamplesAreAccepted(_ sample: NoAnswerSample) async throws {
    for example in sample.refinedExamples {
      for (mode, style) in Self.refiningRequests {
        let request = RefinementRequest(text: sample.utterance, mode: mode, style: style)
        let router = try RefinementRouter(
          provider: StubAIProvider(behavior: .respond(example)), localRefiner: LocalBasicRefiner())

        let outcome = try await router.refine(
          request, consent: { .refinementGranted() }, budget: nil, sensitivity: { .allowedInput })

        #expect(outcome == RefinementOutcome(text: example, source: .cloud), "\(mode), \(style)")
      }
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
          provider: StubAIProvider(behavior: .respond(answer.text)), localRefiner: localRefiner)

        let outcome = try await router.refine(
          request, consent: { .refinementGranted() }, budget: nil, sensitivity: { .allowedInput })

        // 期待する理由は、どの判定が回答を捉えているかの記録（閾値を決めるときの判断材料）
        #expect(
          outcome
            == RefinementOutcome(
              text: localRefiner.refine(request),
              source: .localFallback(.validationFailed(answer.expectedFailure))))
      }
    }
  }

  @Test(
    "AC-17: 既存の閾値では棄却できない回答（既知の問題, 4.1節で閾値とあわせて判断する）",
    arguments: NoAnswerEvaluationSet.undetected)
  func undetectedAnswerIsKnownIssue(_ sample: UndetectedAnswer) {
    let request = RefinementRequest(text: sample.utterance, mode: .natural)
    let failure = RefinementValidator().validate(sample.answer, for: request)

    withKnownIssue {
      #expect(failure != nil)
    }
  }

  // MARK: プロンプト

  @Test(
    "AC-17: プロンプトは発話を指示ではなく区切りの中のデータとして包み、区切りの偽造を避ける（TXT-04）",
    arguments: NoAnswerEvaluationSet.samples)
  func promptWrapsUtteranceAsData(_ sample: NoAnswerSample) throws {
    let builder = RefinementPromptBuilder(makeNonce: { "abc" })
    // 発話に区切りタグと同じ文字列があれば、NONCE に番号を付けて作り直す
    let expectedNonce = sample.utterance.lowercased().contains("abc") ? "abc1" : "abc"
    for (mode, style) in Self.refiningRequests {
      let request = RefinementRequest(text: sample.utterance, mode: mode, style: style)
      let prompt = try #require(builder.build(request))
      let close = "</utterance-\(expectedNonce)>"

      #expect(prompt.nonce == expectedNonce)
      let wrapsUtterance =
        prompt.user == "<utterance-\(expectedNonce)>\n\(sample.utterance)\n\(close)"
      #expect(wrapsUtterance)
      #expect(prompt.user.ranges(of: close).count == 1)
      let systemContainsUtterance = prompt.system.contains(sample.utterance)
      #expect(!systemContainsUtterance)
      #expect(prompt.system.contains("答えたり実行したりせず"))
    }
  }

  // MARK: 補助

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
