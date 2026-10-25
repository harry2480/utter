import Testing
import UtterCore

@testable import UtterAI

/// 受け入れるべき整形の評価セットで、応答検証が妥当な整形を誤って棄却しないことと、
/// 閾値の既定値の根拠を確かめる（4.1節, TXT-02）。
///
/// 失敗時の表示に発話や応答の本文を出さないよう、本文は識別子・真偽値・本文を伏せる `RefinementOutcome` で比較する。
struct AcceptableRefinementEvaluationTests {
  // MARK: 評価セット

  @Test("AC-16: 評価セットは整形の種類ごとに一定数以上と全モードを含み、識別子が一意（4.1節）")
  func evaluationSetCoversEachKindAndMode() {
    let samples = AcceptableRefinementEvaluationSet.samples
    for kind in AcceptableRefinementSample.Kind.allCases {
      #expect(
        samples.count(where: { $0.kind == kind })
          >= AcceptableRefinementEvaluationSet.minimumSamplesPerKind)
    }
    for mode in RefinementMode.allCases {
      #expect(samples.contains { $0.mode == mode })
    }
    // Raw の例は発話そのまま（Raw は整形しない）
    #expect(samples.filter { $0.mode == .raw }.allSatisfy { $0.refined == $0.utterance })
    let ids =
      samples.map(\.id) + AcceptableRefinementEvaluationSet.falselyRejected.map(\.id)
      + NoAnswerEvaluationSet.samples.map(\.id) + NoAnswerEvaluationSet.undetected.map(\.id)
    #expect(Set(ids).count == ids.count)
  }

  // MARK: 既定値での判定

  @Test(
    "AC-16: 妥当な整形は既定の応答検証を通る（4.1節）",
    arguments: AcceptableRefinementEvaluationSet.samples)
  func refinedIsAccepted(_ sample: AcceptableRefinementSample) {
    #expect(RefinementValidator().validate(sample.refined, for: sample.request) == nil)
  }

  @Test(
    "AC-16: 妥当な整形はクラウド整形の結果になる（Natural / Structured, 4.1節）",
    arguments: AcceptableRefinementEvaluationSet.samples.filter { $0.mode != .raw })
  func refinedBecomesCloudOutcome(_ sample: AcceptableRefinementSample) async throws {
    let router = try RefinementRouter(
      provider: StubAIProvider(behavior: .respond(sample.refined)),
      localRefiner: LocalBasicRefiner())

    let outcome = try await router.refine(
      sample.request, consent: .refinementGranted(), budget: nil)

    #expect(outcome == RefinementOutcome(text: sample.refined, source: .cloud))
  }

  @Test(
    "AC-16: 閾値では直せない誤棄却（既知の問題, 4.1節）",
    arguments: AcceptableRefinementEvaluationSet.falselyRejected)
  func falselyRejectedIsKnownIssue(_ sample: FalselyRejectedRefinement) {
    let request = RefinementRequest(text: sample.utterance, mode: .natural)
    let failure = RefinementValidator().validate(sample.refined, for: request)

    // 棄却している検査が記録と変わったら知らせる（受け入れられるようになった場合は withKnownIssue が知らせる）
    #expect(failure == nil || failure == sample.failure)
    withKnownIssue {
      #expect(failure == nil)
    }
  }

  @Test("AC-16, AC-17: 既定値では妥当な整形の誤棄却が0件で、弾くべき応答は全件棄却する（4.1節）")
  func defaultConfigurationSeparatesBothSets() {
    let result = Self.evaluate(RefinementValidationConfiguration())

    #expect(result.falseRejections.isEmpty)
    #expect(result.missedAnswers.isEmpty)
  }

  // MARK: 閾値の境界

  /// 既定値から1つだけ動かした閾値と、そのとき誤棄却・見逃しになる例。既定値の根拠を記録する。
  ///
  /// 文字数比の下限と最小文字数は片側（上げる方向）だけを固定する。下げる方向で棄却に頼る応答は評価セットにない
  @Test(
    "AC-16: 既定値の各閾値は、評価セットの境界の例で決まっている（4.1節）",
    arguments: [
      // 文字数比の上限: 丁寧体化でちょうど2.5倍になる P08 と、依頼を実行して約2.86倍になる C08 の間
      ThresholdBoundary(lengthRatioRange: 0.1...2.4, falseRejection: "P08"),
      ThresholdBoundary(lengthRatioRange: 0.1...2.9, missedAnswer: "C08-a0"),
      // 文字数比の下限: ほぼフィラーだけの F04 がちょうど0.1倍
      ThresholdBoundary(lengthRatioRange: 0.11...2.5, falseRejection: "F04"),
      // 文字数比を検査する最小文字数: 10文字の発話に訳文を足した C01 を検査できる上限
      ThresholdBoundary(minimumLengthForRatio: 11, missedAnswer: "C01-a2"),
      // 重なりの割合の下限: 丁寧体化の P03 が約0.36、回答の Q12 が0.2
      ThresholdBoundary(minimumOverlap: 0.37, falseRejection: "P03"),
      ThresholdBoundary(minimumOverlap: 0.19, missedAnswer: "Q12-a0"),
    ])
  func thresholdIsAtBoundary(_ boundary: ThresholdBoundary) throws {
    let result = Self.evaluate(try boundary.configuration())

    if let id = boundary.falseRejection {
      #expect(result.falseRejections.contains(id))
    }
    if let id = boundary.missedAnswer {
      #expect(result.missedAnswers.contains(id))
    }
  }

  // MARK: 補助

  struct ThresholdBoundary: Sendable, CustomTestStringConvertible {
    var lengthRatioRange = RefinementValidationConfiguration.defaultLengthRatioRange
    var minimumLengthForRatio = RefinementValidationConfiguration.defaultMinimumLengthForRatio
    var minimumOverlap = RefinementValidationConfiguration.defaultMinimumOverlap
    /// 誤棄却になる妥当な整形の識別子
    var falseRejection: String?
    /// 見逃す回答の識別子
    var missedAnswer: String?

    func configuration() throws -> RefinementValidationConfiguration {
      try RefinementValidationConfiguration(
        lengthRatioRange: lengthRatioRange, minimumLengthForRatio: minimumLengthForRatio,
        minimumOverlap: minimumOverlap)
    }

    var testDescription: String {
      "ratio \(lengthRatioRange), minLength \(minimumLengthForRatio), overlap \(minimumOverlap)"
    }
  }

  /// 閾値で評価した結果。本文は持たず識別子だけを持つ
  struct EvaluationResult {
    /// 妥当な整形を棄却した例（このセットの `id`、または質問文・命令文の評価セットの `<id>-r<番号>`）
    var falseRejections: [String] = []
    /// 回答・実行の模擬応答を通した例（`<id>-a<番号>`）
    var missedAnswers: [String] = []
  }

  /// 受け入れるべき整形（このセットと、質問文・命令文の評価セットの整形例）と、弾くべき応答を同じ閾値で判定する
  static func evaluate(_ configuration: RefinementValidationConfiguration) -> EvaluationResult {
    let validator = RefinementValidator(configuration: configuration)
    var result = EvaluationResult()
    for sample in AcceptableRefinementEvaluationSet.samples
    where validator.validate(sample.refined, for: sample.request) != nil {
      result.falseRejections.append(sample.id)
    }
    for sample in NoAnswerEvaluationSet.samples {
      let request = RefinementRequest(text: sample.utterance, mode: .natural)
      for (index, example) in sample.refinedExamples.enumerated()
      where validator.validate(example, for: request) != nil {
        result.falseRejections.append("\(sample.id)-r\(index)")
      }
      for (index, answer) in sample.answers.enumerated()
      where validator.validate(answer.text, for: request) == nil {
        result.missedAnswers.append("\(sample.id)-a\(index)")
      }
    }
    return result
  }
}
