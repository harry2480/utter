/// ユーザー辞書（TXT-03）。辞書語と用語置換ルールを持つ。
public struct UserDictionary: Hashable, Sendable {
  public let terms: [DictionaryTerm]
  /// 定義順の置換ルール
  public let rules: [ReplacementRule]
  /// 先頭文字ごとに、パターンの長い順に並べたルール
  let matchersByFirstCharacter: [String: [ReplacementMatcher]]

  /// 同じ位置で同じ長さの一致が起こりうるルールの組は、優先順位を決められないため拒否する。
  public init(
    terms: [DictionaryTerm] = [], rules: [ReplacementRule] = []
  ) throws(UserDictionaryError) {
    for (index, rule) in rules.enumerated() {
      if let other = rules[..<index].firstIndex(where: { $0.conflicts(with: rule) }) {
        throw .conflictingRules(first: other, second: index)
      }
    }
    self.terms = terms
    self.rules = rules
    matchersByFirstCharacter = Dictionary(
      grouping: rules.map(ReplacementMatcher.init), by: \.firstCharacterKey
    ).mapValues { $0.sorted { $0.length > $1.length } }
  }

  /// 辞書語を保護対象として扱う抽出器（TXT-02 の保持チェック用）。
  public var protectedSpanExtractor: ProtectedSpanExtractor {
    ProtectedSpanExtractor(dictionaryTerms: terms.map(\.spelling))
  }
}

/// 辞書語。整形やクラウド整形の前後で表記を保持する語（TXT-02, CTX-03）。
public struct DictionaryTerm: Hashable, Sendable {
  public let spelling: String

  public init(_ spelling: String) throws(UserDictionaryError) {
    guard !spelling.isEmpty else { throw .emptySpelling }
    self.spelling = spelling
  }
}

/// 用語置換ルール。読みや STT の誤変換を正しい表記に直す。
public struct ReplacementRule: Hashable, Sendable {
  /// 置換前の読み・誤変換
  public let pattern: String
  /// 置換後の表記
  public let replacement: String
  /// 大文字小文字を区別せずに照合するか。`lowercased()` 同士で比べるため英字以外の大文字小文字にも効く。
  /// 全角英字と半角英字は区別する
  public let ignoresCase: Bool

  public init(
    pattern: String, replacement: String, ignoresCase: Bool = false
  ) throws(UserDictionaryError) {
    guard !pattern.isEmpty else { throw .emptyPattern }
    self.pattern = pattern
    self.replacement = replacement
    self.ignoresCase = ignoresCase
  }

  /// 同じテキストに対して両方が一致しうるか。
  func conflicts(with other: ReplacementRule) -> Bool {
    guard ignoresCase || other.ignoresCase else { return pattern == other.pattern }
    return pattern.count == other.pattern.count
      && pattern.lowercased() == other.pattern.lowercased()
  }
}

/// 辞書の検証エラー。利用者の入力を含めず、ルールの位置だけを持つ。
public enum UserDictionaryError: Error, Hashable, Sendable {
  case emptySpelling
  case emptyPattern
  /// 定義順の位置が `first` と `second` のルールが、同じテキストに一致しうる
  case conflictingRules(first: Int, second: Int)
}
