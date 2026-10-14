/// 文字誤り率（CER, 9章）。正解と認識結果を同じ規則で正規化してから編集距離を数える。
public struct CharacterErrorRate: Sendable {
  public let normalizer: TextNormalizer

  public init(normalizer: TextNormalizer = TextNormalizer()) {
    self.normalizer = normalizer
  }

  /// 1発話の誤り数。分母は正規化後の正解の文字数。
  public func count(reference: String, hypothesis: String) -> ErrorCount {
    let normalizedReference = normalizer.normalize(reference)
    let normalizedHypothesis = normalizer.normalize(hypothesis)
    return ErrorCount(
      errors: EditDistance.between(normalizedReference, normalizedHypothesis),
      total: normalizedReference.count)
  }
}
