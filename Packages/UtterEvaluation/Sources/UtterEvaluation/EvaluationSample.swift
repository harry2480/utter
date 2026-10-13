/// 評価セットの1発話と、その評価結果（9章）。
///
/// 評価用音声はリポジトリに含めず、正解テキストと認識・整形の結果だけを記録する。
/// 発話内容に実在の個人情報を含めない。
public struct EvaluationSample: Codable, Hashable, Sendable {
  /// 発話の識別子（評価セット内で一意）
  public let id: String
  public let category: EvaluationCategory
  /// 発話どおりの正解（フィラー・言い直しも含める）
  public let reference: String
  /// 用語単位で正答率を測る語（辞書語・開発用語・英単語）。正解に表記どおり含まれていること
  public let terms: [String]?
  /// STT 単体の結果。未実施なら `nil`
  public let sttOutput: String?
  /// AI 整形後の結果。未実施なら `nil`
  public let refinedOutput: String?
  /// 整形後の結果に対する重大な意味改変の判定。未判定なら `nil`、改変なしなら空
  public let meaningChanges: [MeaningChange]?

  public init(
    id: String,
    category: EvaluationCategory,
    reference: String,
    terms: [String]? = nil,
    sttOutput: String? = nil,
    refinedOutput: String? = nil,
    meaningChanges: [MeaningChange]? = nil
  ) {
    self.id = id
    self.category = category
    self.reference = reference
    self.terms = terms
    self.sttOutput = sttOutput
    self.refinedOutput = refinedOutput
    self.meaningChanges = meaningChanges
  }
}

/// 評価セットの不備。発話本文は含めず、識別子だけを持つ。
public enum EvaluationSampleError: Error, Hashable, Sendable {
  case duplicateID(String)
  case emptyReference(id: String)
  /// 用語が正解に表記どおり含まれていない
  case termNotInReference(id: String)
}

extension EvaluationSample {
  /// 評価セット全体の不備を確認する。
  public static func validate(_ samples: [EvaluationSample]) throws(EvaluationSampleError) {
    var seen: Set<String> = []
    for sample in samples {
      guard seen.insert(sample.id).inserted else {
        throw .duplicateID(sample.id)
      }
      guard !TextNormalizer().normalize(sample.reference).isEmpty else {
        throw .emptyReference(id: sample.id)
      }
      for term in sample.terms ?? []
      where TermAccuracy.occurrences(of: term, in: sample.reference) == 0 {
        throw .termNotInReference(id: sample.id)
      }
    }
  }
}
