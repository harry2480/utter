import Foundation

/// ユーザー辞書の編集（TXT-03, AC-07）。辞書語と置換ルールの追加・更新・削除と、その検証を持つ。
///
/// 編集のたびに `UserDictionary` を組み立て直し、常に置換に使える状態を保つ。失敗した編集は何も変えない。
/// - 辞書語とパターンは前後の空白・改行を取り除いてから扱い、空になるものは拒否する。置換後の表記はそのまま保つ（空も可）
/// - 同じ辞書語、同じテキストに一致しうるパターン（大文字小文字を無視するルールを含む）は重複として拒否する。
///   比較は String の等価性（Unicode の正規等価）による
/// - 置換ルールは長い一致を優先し、同じ長さで競合するルールは持てないため、定義順は置換結果に影響しない。並べ替えは扱わない
///
/// 保存は呼び出し側が `dictionary` を保存層へ渡して行う。
public struct DictionaryEditor: Hashable, Sendable {
  public private(set) var dictionary: UserDictionary

  public init(dictionary: UserDictionary) {
    self.dictionary = dictionary
  }

  /// 追加した順の辞書語
  public var terms: [DictionaryTerm] { dictionary.terms }
  /// 定義順の置換ルール
  public var rules: [ReplacementRule] { dictionary.rules }

  /// 辞書語を末尾に追加する
  public mutating func addTerm(_ spelling: String) throws(DictionaryEditError) {
    try replaceTerms(with: terms + [try Self.term(spelling)], editedIndex: terms.count)
  }

  /// `index` の辞書語を書き換える
  public mutating func updateTerm(at index: Int, to spelling: String) throws(DictionaryEditError) {
    guard terms.indices.contains(index) else { throw .indexOutOfRange }
    var updated = terms
    updated[index] = try Self.term(spelling)
    try replaceTerms(with: updated, editedIndex: index)
  }

  /// `index` の辞書語を削除する
  public mutating func removeTerm(at index: Int) throws(DictionaryEditError) {
    guard terms.indices.contains(index) else { throw .indexOutOfRange }
    var updated = terms
    updated.remove(at: index)
    try replaceTerms(with: updated, editedIndex: nil)
  }

  /// 置換ルールを末尾に追加する
  public mutating func addRule(
    pattern: String, replacement: String, ignoresCase: Bool = false
  ) throws(DictionaryEditError) {
    let rule = try Self.rule(pattern: pattern, replacement: replacement, ignoresCase: ignoresCase)
    try replaceRules(with: rules + [rule], editedIndex: rules.count)
  }

  /// `index` の置換ルールを書き換える。定義順の位置は変えない
  public mutating func updateRule(
    at index: Int, pattern: String, replacement: String, ignoresCase: Bool = false
  ) throws(DictionaryEditError) {
    guard rules.indices.contains(index) else { throw .indexOutOfRange }
    var updated = rules
    updated[index] = try Self.rule(
      pattern: pattern, replacement: replacement, ignoresCase: ignoresCase)
    try replaceRules(with: updated, editedIndex: index)
  }

  /// `index` の置換ルールを削除する
  public mutating func removeRule(at index: Int) throws(DictionaryEditError) {
    guard rules.indices.contains(index) else { throw .indexOutOfRange }
    var updated = rules
    updated.remove(at: index)
    try replaceRules(with: updated, editedIndex: nil)
  }

  private mutating func replaceTerms(
    with updated: [DictionaryTerm], editedIndex: Int?
  ) throws(DictionaryEditError) {
    if let editedIndex,
      let existing = updated.indices.first(where: {
        $0 != editedIndex && updated[$0] == updated[editedIndex]
      })
    {
      throw .duplicateSpelling(existingIndex: existing)
    }
    dictionary = try Self.dictionary(terms: updated, rules: rules, editedRuleIndex: nil)
  }

  private mutating func replaceRules(
    with updated: [ReplacementRule], editedIndex: Int?
  ) throws(DictionaryEditError) {
    dictionary = try Self.dictionary(terms: terms, rules: updated, editedRuleIndex: editedIndex)
  }

  private static func dictionary(
    terms: [DictionaryTerm], rules: [ReplacementRule], editedRuleIndex: Int?
  ) throws(DictionaryEditError) -> UserDictionary {
    do {
      return try UserDictionary(terms: terms, rules: rules)
    } catch {
      switch error {
      case .conflictingRules(let first, let second):
        throw .duplicatePattern(existingIndex: first == editedRuleIndex ? second : first)
      case .emptySpelling: throw .emptySpelling
      case .emptyPattern: throw .emptyPattern
      }
    }
  }

  private static func term(_ spelling: String) throws(DictionaryEditError) -> DictionaryTerm {
    do {
      return try DictionaryTerm(spelling.trimmingCharacters(in: .whitespacesAndNewlines))
    } catch {
      throw .emptySpelling
    }
  }

  private static func rule(
    pattern: String, replacement: String, ignoresCase: Bool
  ) throws(DictionaryEditError) -> ReplacementRule {
    do {
      return try ReplacementRule(
        pattern: pattern.trimmingCharacters(in: .whitespacesAndNewlines),
        replacement: replacement, ignoresCase: ignoresCase)
    } catch {
      throw .emptyPattern
    }
  }
}

/// 辞書の編集エラー。利用者の入力を含めず、位置だけを持つ。
public enum DictionaryEditError: Error, Hashable, Sendable {
  /// 辞書語が空（空白・改行だけを含む）
  case emptySpelling
  /// 同じ辞書語が `existingIndex` にある
  case duplicateSpelling(existingIndex: Int)
  /// パターンが空（空白・改行だけを含む）
  case emptyPattern
  /// 同じテキストに一致しうるパターンのルールが `existingIndex` にある
  case duplicatePattern(existingIndex: Int)
  /// 指定した位置の辞書語・ルールがない
  case indexOutOfRange
}
