/// 区分ごとの件数と結果（9章, AC-04）。
///
/// STT 単体の誤り（CER・用語正答率）と、AI 整形後の意味改変を分けて集計する。
public struct EvaluationSummary: Hashable, Sendable {
  /// 区分内の発話数
  public var sampleCount = 0
  /// STT 結果がある発話数
  public var sttCount = 0
  /// STT 単体の文字誤り
  public var sttCharacterErrors = ErrorCount.zero
  /// STT 単体の用語の誤り
  public var sttTermErrors = ErrorCount.zero
  /// 整形結果がある発話数
  public var refinedCount = 0
  /// 整形後の用語の誤り
  public var refinedTermErrors = ErrorCount.zero
  /// 意味改変を判定した発話数と、重大な意味改変があった発話数
  public var meaningChanges = ErrorCount.zero

  public init() {}

  mutating func add(_ sample: EvaluationSample, cer: CharacterErrorRate) {
    sampleCount += 1
    let terms = sample.terms ?? []
    if let stt = sample.sttOutput {
      sttCount += 1
      sttCharacterErrors =
        sttCharacterErrors + cer.count(reference: sample.reference, hypothesis: stt)
      sttTermErrors =
        sttTermErrors
        + TermAccuracy.count(terms: terms, reference: sample.reference, hypothesis: stt)
    }
    if let refined = sample.refinedOutput {
      refinedCount += 1
      refinedTermErrors =
        refinedTermErrors
        + TermAccuracy.count(terms: terms, reference: sample.reference, hypothesis: refined)
    }
    if let changes = sample.meaningChanges {
      meaningChanges = meaningChanges + ErrorCount(errors: changes.isEmpty ? 0 : 1, total: 1)
    }
  }
}

public struct EvaluationReport: Hashable, Sendable {
  /// 区分ごとの集計。すべての区分を含む（発話がない区分は件数 0）
  public let categories: [EvaluationCategory: EvaluationSummary]
  /// 全区分の合計
  public let overall: EvaluationSummary

  /// 評価セットを集計する。先に `EvaluationSample.validate(_:)` で不備を確認する。
  public init(
    samples: [EvaluationSample], characterErrorRate: CharacterErrorRate = CharacterErrorRate()
  ) throws(EvaluationSampleError) {
    try EvaluationSample.validate(samples, normalizer: characterErrorRate.normalizer)
    var categories = Dictionary(
      uniqueKeysWithValues: EvaluationCategory.allCases.map { ($0, EvaluationSummary()) })
    var overall = EvaluationSummary()
    for sample in samples {
      categories[sample.category, default: EvaluationSummary()].add(sample, cer: characterErrorRate)
      overall.add(sample, cer: characterErrorRate)
    }
    self.categories = categories
    self.overall = overall
  }

  /// 区分ごとの件数と結果を Markdown の表で返す。発話本文は含めない。
  public func markdownTable() -> String {
    var lines = [
      "| 区分 | 件数 | STT 件数 | CER | STT 用語正答率 | 整形件数 | 整形後 用語正答率 | 意味改変 判定件数 | 重大な意味改変率 |",
      "|---|---:|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for category in EvaluationCategory.allCases {
      lines.append(Self.row(category.displayName, categories[category] ?? EvaluationSummary()))
    }
    lines.append(Self.row("合計", overall))
    return lines.joined(separator: "\n") + "\n"
  }

  private static func row(_ name: String, _ summary: EvaluationSummary) -> String {
    let cells = [
      name,
      String(summary.sampleCount),
      String(summary.sttCount),
      percent(summary.sttCharacterErrors.errorRate, of: summary.sttCharacterErrors),
      percent(summary.sttTermErrors.accuracy, of: summary.sttTermErrors),
      String(summary.refinedCount),
      percent(summary.refinedTermErrors.accuracy, of: summary.refinedTermErrors),
      String(summary.meaningChanges.total),
      percent(summary.meaningChanges.errorRate, of: summary.meaningChanges),
    ]
    return "| " + cells.joined(separator: " | ") + " |"
  }

  /// 小数第1位までの百分率と分母。値がなければ「-」。
  static func percent(_ rate: Double?, of count: ErrorCount) -> String {
    guard let rate else { return "-" }
    let tenths = Int((rate * 1000).rounded())
    let sign = tenths < 0 ? "-" : ""
    let magnitude = abs(tenths)
    return "\(sign)\(magnitude / 10).\(magnitude % 10)% (n=\(count.total))"
  }
}
