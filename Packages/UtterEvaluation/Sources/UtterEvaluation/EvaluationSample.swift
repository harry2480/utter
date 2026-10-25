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
  /// 整形で除くべきフィラー（えー、あのー など）。正解に表記どおり含め、同じフィラーが複数回あれば回数分書く。
  /// 注釈なし（`nil` または空）の発話はフィラー除去成功率の分母に入れない
  public let fillers: [String]?
  /// 自己訂正（言い直す前の語と後の語）。注釈なし（`nil` または空）の発話は自己訂正成功率の分母に入れない
  public let selfCorrections: [SelfCorrection]?

  public init(
    id: String,
    category: EvaluationCategory,
    reference: String,
    terms: [String]? = nil,
    sttOutput: String? = nil,
    refinedOutput: String? = nil,
    meaningChanges: [MeaningChange]? = nil,
    fillers: [String]? = nil,
    selfCorrections: [SelfCorrection]? = nil
  ) {
    self.id = id
    self.category = category
    self.reference = reference
    self.terms = terms
    self.sttOutput = sttOutput
    self.refinedOutput = refinedOutput
    self.meaningChanges = meaningChanges
    self.fillers = fillers
    self.selfCorrections = selfCorrections
  }
}

/// 評価セットの不備。発話本文は含めず、識別子だけを持つ。
public enum EvaluationSampleError: Error, Hashable, Sendable {
  case duplicateID(String)
  case emptyReference(id: String)
  /// 用語が正解に表記どおり含まれていない
  case termNotInReference(id: String)
  /// 整形結果がないのに意味改変を判定している
  case meaningChangesWithoutRefinedOutput(id: String)
  /// フィラーが、正規化後の正解に注釈の件数だけ含まれていない
  case fillerNotInReference(id: String)
  /// 自己訂正の語が、正規化後の正解に注釈の件数だけ含まれていない
  case selfCorrectionNotInReference(id: String)
  /// 言い直す前と後の語が、正規化後に同じ
  case selfCorrectionUnchanged(id: String)
}

extension EvaluationSample {
  /// 評価セット全体の不備を確認する。正解が空かどうかは集計と同じ `normalizer` で判定する。
  public static func validate(
    _ samples: [EvaluationSample], normalizer: TextNormalizer = TextNormalizer()
  ) throws(EvaluationSampleError) {
    var seen: Set<String> = []
    for sample in samples {
      guard seen.insert(sample.id).inserted else {
        throw .duplicateID(sample.id)
      }
      guard !normalizer.normalize(sample.reference).isEmpty else {
        throw .emptyReference(id: sample.id)
      }
      for term in sample.terms ?? []
      where TermAccuracy.occurrences(of: term, in: sample.reference) == 0 {
        throw .termNotInReference(id: sample.id)
      }
      if sample.meaningChanges != nil, sample.refinedOutput == nil {
        throw .meaningChangesWithoutRefinedOutput(id: sample.id)
      }
      try validateAnnotations(of: sample, normalizer: normalizer)
    }
  }

  /// フィラー・自己訂正の注釈が正解に含まれているかを確かめる。整形結果がなくても注釈は書いてよい。
  private static func validateAnnotations(
    of sample: EvaluationSample, normalizer: TextNormalizer
  ) throws(EvaluationSampleError) {
    let corrections = sample.selfCorrections ?? []
    for correction in corrections
    where normalizer.normalize(correction.retracted) == normalizer.normalize(correction.corrected) {
      throw .selfCorrectionUnchanged(id: sample.id)
    }
    let missing = RefinementSuccess(
      fillers: sample.fillers ?? [], selfCorrections: corrections, normalizer: normalizer
    ).missingWords(in: sample.reference)
    if missing.fillers {
      throw .fillerNotInReference(id: sample.id)
    }
    if missing.selfCorrections {
      throw .selfCorrectionNotInReference(id: sample.id)
    }
  }
}
