import UtterText

/// クラウド整形の応答が整形結果として使えるかを判定する（4.1節, TXT-04）。
///
/// 判定はルールベースで、モデルによる判定は行わない。そのため次は検出できない。
/// - 疑問符も「〜ですか」などもない質問への回答
/// - 発話の後ろに足された回答（発話の文字が応答に残っている場合）
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
    if Self.containsAddedPhrase(
      configuration.preamblePhrases, in: refined, original: original, prefixOnly: true)
      || Self.containsAddedPhrase(
        configuration.refusalPhrases, in: refined, original: original, prefixOnly: false)
    {
      return .preambleOrRefusal
    }
    if Self.isQuestion(original) && !Self.isQuestion(refined) {
      return .questionAnswered
    }
    let checker = ProtectionChecker(dictionaryTerms: request.dictionaryTerms)
    if !checker.violations(original: original, refined: refined).isEmpty {
      return .protectedContentChanged
    }
    if let overlap = Self.characterOverlap(of: refinedCharacters, in: originalCharacters),
      overlap < configuration.minimumOverlap
    {
      return .unrelatedContent
    }
    if originalCharacters.count >= configuration.minimumLengthForRatio {
      let ratio = Double(refinedCharacters.count) / Double(originalCharacters.count)
      if !configuration.lengthRatioRange.contains(ratio) {
        return .lengthRatioOutOfRange
      }
    }
    return nil
  }

  /// 整形前にない定型句が応答にあるか。英字の大文字小文字は区別しない。`EditValidator` と共用する。
  static func containsAddedPhrase(
    _ phrases: [String],
    in refined: String,
    original: String,
    prefixOnly: Bool
  ) -> Bool {
    let refined = String(refined.drop(while: \.isWhitespace)).lowercased()
    let original = original.lowercased()
    return phrases.contains { phrase in
      let phrase = phrase.lowercased()
      let found = prefixOnly ? refined.hasPrefix(phrase) : refined.contains(phrase)
      return found && !original.contains(phrase)
    }
  }

  /// 文末を閉じる記号。疑問かどうかの判定では無視する
  private static let closingCharacters: Set<Character> = [
    "。", "、", ".", ",", "！", "!", "」", "』", "）", ")", "\"", "”", "'", "’", "…", "〜", "~",
  ]
  /// 疑問の「か」の直前に来る文字（「ですか」「でしょうか」「ないか」「のか」「するか」「したか」「ませんか」）
  private static let questionParticlePredecessors: Set<Character> = [
    "す", "う", "い", "の", "る", "た", "ん",
  ]

  /// 文末が疑問符か、「ですか」などの疑問の「か」で終わるか。
  ///
  /// 「明らか」「とか」「何か」のような「か」で終わる語は疑問とみなさない。
  private static func isQuestion(_ text: String) -> Bool {
    let body = text.reversed().drop { $0.isWhitespace || closingCharacters.contains($0) }
    guard let last = body.first else {
      return false
    }
    if last == "？" || last == "?" {
      return true
    }
    guard last == "か", let predecessor = body.dropFirst().first else {
      return false
    }
    return questionParticlePredecessors.contains(predecessor)
  }

  /// 比較に使う文字（文字と数字）。空白・句読点・記号は除く。
  private static func contentCharacters(of text: String) -> [Character] {
    text.filter { $0.isLetter || $0.isNumber }.map(\.self)
  }

  /// 整形後に現れる文字の種類のうち、整形前にも現れるものの割合。どちらかが文字を持たない場合は `nil`。
  private static func characterOverlap(
    of refined: [Character],
    in original: [Character]
  ) -> Double? {
    let refinedSet = Set(refined)
    let originalSet = Set(original)
    guard !refinedSet.isEmpty, !originalSet.isEmpty else {
      return nil
    }
    return Double(refinedSet.intersection(originalSet).count) / Double(refinedSet.count)
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
  public static let defaultLengthRatioRange: ClosedRange<Double> = 0.1...2.5
  public static let defaultMinimumLengthForRatio = 10
  public static let defaultMinimumOverlap = 0.3
  /// 丁寧化で現れうる「承知しました」「申し訳ありません」単独は含めない
  public static let defaultPreamblePhrases = [
    "以下が", "以下は整形", "以下に整形", "以下のように整形", "整形しました", "整形した文章", "整形後の文章", "整形結果",
    "Here is the", "Here's the refined", "Here is your", "Here's your", "Sure, here",
    "Certainly, here",
    "As an AI",
  ]
  public static let defaultRefusalPhrases = [
    "お応えできません", "お答えできません", "お手伝いできません", "対応いたしかねます",
    "I can't help", "I cannot help", "I'm unable to", "I am unable to",
  ]

  /// 整形後と整形前の文字数比（空白・句読点・記号を除く）の許容範囲
  public let lengthRatioRange: ClosedRange<Double>
  /// 文字数比を検査する整形前の最小文字数。短い発話は丁寧化などで比が大きく振れるため検査しない
  public let minimumLengthForRatio: Int
  /// 整形後に現れる文字の種類のうち、整形前にも現れるものの割合の下限
  public let minimumOverlap: Double
  /// 整形前になく、応答の先頭にあれば整形以外の出力とみなす前置きの句
  public let preamblePhrases: [String]
  /// 整形前になく、応答のどこかにあれば整形以外の出力とみなす拒否の句
  public let refusalPhrases: [String]

  public init() {
    lengthRatioRange = Self.defaultLengthRatioRange
    minimumLengthForRatio = Self.defaultMinimumLengthForRatio
    minimumOverlap = Self.defaultMinimumOverlap
    preamblePhrases = Self.defaultPreamblePhrases
    refusalPhrases = Self.defaultRefusalPhrases
  }

  public init(
    lengthRatioRange: ClosedRange<Double> = defaultLengthRatioRange,
    minimumLengthForRatio: Int = defaultMinimumLengthForRatio,
    minimumOverlap: Double = defaultMinimumOverlap,
    preamblePhrases: [String] = defaultPreamblePhrases,
    refusalPhrases: [String] = defaultRefusalPhrases
  ) throws(RefinementValidationConfigurationError) {
    guard lengthRatioRange.lowerBound >= 0, lengthRatioRange.upperBound.isFinite else {
      throw .invalidLengthRatioRange
    }
    guard minimumLengthForRatio >= 1 else {
      throw .invalidMinimumLengthForRatio
    }
    guard (0...1).contains(minimumOverlap) else {
      throw .invalidMinimumOverlap
    }
    guard !preamblePhrases.contains(where: \.isEmpty), !refusalPhrases.contains(where: \.isEmpty)
    else {
      throw .emptyPhrase
    }
    self.lengthRatioRange = lengthRatioRange
    self.minimumLengthForRatio = minimumLengthForRatio
    self.minimumOverlap = minimumOverlap
    self.preamblePhrases = preamblePhrases
    self.refusalPhrases = refusalPhrases
  }
}

public enum RefinementValidationConfigurationError: Error, Hashable, Sendable {
  case invalidLengthRatioRange
  case invalidMinimumLengthForRatio
  case invalidMinimumOverlap
  case emptyPhrase
}
