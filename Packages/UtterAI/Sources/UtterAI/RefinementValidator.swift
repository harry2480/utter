import UtterText

/// クラウド整形の応答が整形結果として使えるかを判定する（4.1節, TXT-04）。
///
/// 判定はルールベースで、モデルによる判定は行わない。
public struct RefinementValidator: Sendable {
  public let configuration: RefinementValidationConfiguration

  public init(
    configuration: RefinementValidationConfiguration = RefinementValidationConfiguration()
  ) {
    self.configuration = configuration
  }

  /// 応答に問題があれば最初に見つかった理由を返し、問題がなければ `nil` を返す。
  public func validate(
    _ refined: String,
    for request: RefinementRequest
  ) -> RefinementValidationFailure? {
    let original = request.text
    let refinedCharacters = Self.contentCharacters(of: refined)
    let originalCharacters = Self.contentCharacters(of: original)

    if refined.allSatisfy(\.isWhitespace) {
      return .empty
    }
    if startsWithPreamble(refined, original: original) {
      return .preambleOrRefusal
    }
    if Self.isQuestion(original) && !Self.isQuestion(refined) {
      return .questionAnswered
    }
    let checker = ProtectionChecker(dictionaryTerms: request.dictionaryTerms)
    if !checker.violations(original: original, refined: refined).isEmpty {
      return .protectedContentChanged
    }
    if let overlap = Self.bigramOverlap(of: refinedCharacters, in: originalCharacters),
      overlap < configuration.minimumOverlap
    {
      return .unrelatedContent
    }
    if !originalCharacters.isEmpty {
      let ratio = Double(refinedCharacters.count) / Double(originalCharacters.count)
      if !configuration.lengthRatioRange.contains(ratio) {
        return .lengthRatioOutOfRange
      }
    }
    return nil
  }

  /// 整形前にない前置き・拒否の定型句で応答が始まるか。
  private func startsWithPreamble(_ refined: String, original: String) -> Bool {
    let trimmed = refined.drop(while: \.isWhitespace)
    return configuration.preamblePhrases.contains { phrase in
      trimmed.hasPrefix(phrase) && !original.contains(phrase)
    }
  }

  /// 文末が疑問符か「か」で終わるか。文末の句読点・空白は無視する。
  private static func isQuestion(_ text: String) -> Bool {
    let trailing: Set<Character> = ["。", "、", ".", ",", "！", "!"]
    let body = text.reversed().drop { $0.isWhitespace || trailing.contains($0) }
    guard let last = body.first else {
      return false
    }
    return last == "？" || last == "?" || last == "か"
  }

  /// 比較に使う文字（文字と数字）。空白・句読点・記号は除く。
  private static func contentCharacters(of text: String) -> [Character] {
    text.filter { $0.isLetter || $0.isNumber }.map(\.self)
  }

  /// 整形後の文字 bigram のうち、整形前にも現れるものの割合。どちらかが bigram を持たない場合は `nil`。
  private static func bigramOverlap(
    of refined: [Character],
    in original: [Character]
  ) -> Double? {
    let refinedBigrams = bigrams(of: refined)
    let originalBigrams = bigrams(of: original)
    guard !refinedBigrams.isEmpty, !originalBigrams.isEmpty else {
      return nil
    }
    let shared = refinedBigrams.intersection(originalBigrams).count
    return Double(shared) / Double(refinedBigrams.count)
  }

  private static func bigrams(of characters: [Character]) -> Set<String> {
    guard characters.count >= 2 else {
      return []
    }
    return Set((1..<characters.count).map { String([characters[$0 - 1], characters[$0]]) })
  }
}

/// 整形応答を使えないと判定した理由（4.1節）。本文は持たない。
public enum RefinementValidationFailure: Hashable, Sendable, CaseIterable {
  /// 空応答
  case empty
  /// STT 結果に対する文字数比が許容範囲外
  case lengthRatioOutOfRange
  /// 数字・URL・コード・辞書語が保持されていない
  case protectedContentChanged
  /// 前置き・拒否文などの整形以外の出力
  case preambleOrRefusal
  /// 質問の発話に回答した（TXT-04）
  case questionAnswered
  /// 発話と関係の薄い内容（回答・実行結果など, TXT-04）
  case unrelatedContent
}

/// 応答検証の閾値。既定値は暫定で、最終値は Phase 2 の評価セットで決める（4.1節）。
public struct RefinementValidationConfiguration: Hashable, Sendable {
  public static let defaultLengthRatioRange: ClosedRange<Double> = 0.3...2.0
  public static let defaultMinimumOverlap = 0.3
  public static let defaultPreamblePhrases = [
    "以下", "整形しました", "整形した", "整形後", "整形結果", "承知しました", "かしこまりました", "了解しました",
    "申し訳ありません", "申し訳ございません", "お答えします", "回答します",
    "Here is", "Here's", "Sure,", "Sure!", "Sure.", "Certainly", "I'm sorry", "I cannot", "I can't",
    "As an AI",
  ]

  /// 整形後と整形前の文字数比（空白・句読点・記号を除く）の許容範囲
  public let lengthRatioRange: ClosedRange<Double>
  /// 整形後の文字 bigram のうち、整形前にも現れるものの割合の下限
  public let minimumOverlap: Double
  /// 整形前になく、応答の先頭にあれば整形以外の出力とみなす定型句
  public let preamblePhrases: [String]

  public init() {
    lengthRatioRange = Self.defaultLengthRatioRange
    minimumOverlap = Self.defaultMinimumOverlap
    preamblePhrases = Self.defaultPreamblePhrases
  }

  public init(
    lengthRatioRange: ClosedRange<Double> = defaultLengthRatioRange,
    minimumOverlap: Double = defaultMinimumOverlap,
    preamblePhrases: [String] = defaultPreamblePhrases
  ) throws(RefinementValidationConfigurationError) {
    guard lengthRatioRange.lowerBound >= 0, lengthRatioRange.upperBound.isFinite else {
      throw .invalidLengthRatioRange
    }
    guard (0...1).contains(minimumOverlap) else {
      throw .invalidMinimumOverlap
    }
    guard !preamblePhrases.contains(where: \.isEmpty) else {
      throw .emptyPreamblePhrase
    }
    self.lengthRatioRange = lengthRatioRange
    self.minimumOverlap = minimumOverlap
    self.preamblePhrases = preamblePhrases
  }
}

public enum RefinementValidationConfigurationError: Error, Hashable, Sendable {
  case invalidLengthRatioRange
  case invalidMinimumOverlap
  case emptyPreamblePhrase
}
