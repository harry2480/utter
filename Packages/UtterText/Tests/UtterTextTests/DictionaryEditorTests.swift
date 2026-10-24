import Testing

@testable import UtterText

struct DictionaryEditorTests {
  private var editor: DictionaryEditor

  init() throws {
    editor = DictionaryEditor(dictionary: try UserDictionary())
  }

  @Test("TXT-03: 辞書語を追加・更新・削除でき、追加した順に並ぶ")
  mutating func editsTerms() throws {
    try editor.addTerm("Claude")
    try editor.addTerm("  utter\n")
    try editor.addTerm("GRDB")

    try editor.updateTerm(at: 0, to: "Claude Code")
    try editor.removeTerm(at: 2)

    #expect(editor.terms.map(\.spelling) == ["Claude Code", "utter"])
    #expect(editor.dictionary.terms == editor.terms)
  }

  @Test("TXT-03: 辞書語は空と重複を拒否し、失敗した編集は何も変えない")
  mutating func rejectsInvalidTerms() throws {
    try editor.addTerm("Claude")
    try editor.addTerm("utter")
    let before = editor

    #expect(throws: DictionaryEditError.emptySpelling) { try editor.addTerm(" \n ") }
    #expect(throws: DictionaryEditError.duplicateSpelling(existingIndex: 0)) {
      try editor.addTerm(" Claude ")
    }
    #expect(throws: DictionaryEditError.duplicateSpelling(existingIndex: 1)) {
      try editor.updateTerm(at: 0, to: "utter")
    }
    #expect(throws: DictionaryEditError.emptySpelling) { try editor.updateTerm(at: 0, to: "") }
    #expect(editor == before)
  }

  @Test("TXT-03: 正規化形式が違うだけの辞書語・パターンは重複として扱う")
  mutating func treatsCanonicallyEquivalentValuesAsDuplicates() throws {
    try editor.addTerm("が")
    try editor.addRule(pattern: "が", replacement: "1")

    #expect(throws: DictionaryEditError.duplicateSpelling(existingIndex: 0)) {
      try editor.addTerm("か\u{3099}")
    }
    #expect(throws: DictionaryEditError.duplicatePattern(existingIndex: 0)) {
      try editor.addRule(pattern: "か\u{3099}", replacement: "2")
    }
  }

  @Test("TXT-03: 自分自身と同じ値への更新は重複にしない")
  mutating func updatingToSameValueSucceeds() throws {
    try editor.addTerm("utter")
    try editor.addRule(pattern: "github", replacement: "GitHub")

    try editor.updateTerm(at: 0, to: "utter")
    try editor.updateRule(at: 0, pattern: "github", replacement: "GitHub", ignoresCase: true)

    #expect(editor.terms.map(\.spelling) == ["utter"])
    #expect(
      editor.rules == [
        try ReplacementRule(pattern: "github", replacement: "GitHub", ignoresCase: true)
      ])
  }

  @Test("TXT-03: 置換ルールを追加・更新・削除でき、更新しても定義順を保つ")
  mutating func editsRules() throws {
    try editor.addRule(pattern: "くろーど", replacement: "Claude")
    try editor.addRule(pattern: " ぎっとはぶ ", replacement: "GitHub")
    try editor.addRule(pattern: "けす", replacement: "")

    try editor.updateRule(at: 0, pattern: "くろーど", replacement: "Claude Code")
    try editor.removeRule(at: 2)

    #expect(
      editor.rules == [
        try ReplacementRule(pattern: "くろーど", replacement: "Claude Code"),
        try ReplacementRule(pattern: "ぎっとはぶ", replacement: "GitHub"),
      ])
    #expect(editor.dictionary.applyingReplacements(to: "くろーどとぎっとはぶ") == "Claude CodeとGitHub")
  }

  @Test("TXT-03: 置換後の表記は前後の空白も含めてそのまま保つ")
  mutating func keepsReplacementAsIs() throws {
    try editor.addRule(pattern: "てん", replacement: " 、")

    #expect(editor.rules.first?.replacement == " 、")
  }

  @Test("TXT-03: 置換ルールは空のパターンと、同じテキストに一致しうるパターンを拒否し、失敗した編集は何も変えない")
  mutating func rejectsInvalidRules() throws {
    try editor.addRule(pattern: "github", replacement: "GitHub")
    try editor.addRule(pattern: "swift", replacement: "Swift")
    let before = editor

    #expect(throws: DictionaryEditError.emptyPattern) {
      try editor.addRule(pattern: "\t", replacement: "x")
    }
    #expect(throws: DictionaryEditError.duplicatePattern(existingIndex: 0)) {
      try editor.addRule(pattern: "github", replacement: "GitHub2")
    }
    #expect(throws: DictionaryEditError.duplicatePattern(existingIndex: 0)) {
      try editor.addRule(pattern: "GitHub", replacement: "GitHub", ignoresCase: true)
    }
    #expect(throws: DictionaryEditError.duplicatePattern(existingIndex: 1)) {
      try editor.updateRule(at: 0, pattern: "SWIFT", replacement: "Swift", ignoresCase: true)
    }
    #expect(throws: DictionaryEditError.emptyPattern) {
      try editor.updateRule(at: 1, pattern: "", replacement: "Swift")
    }
    #expect(editor == before)
  }

  @Test("TXT-03: 範囲外の位置の更新・削除は拒否する")
  mutating func rejectsOutOfRangeIndex() throws {
    try editor.addTerm("utter")
    try editor.addRule(pattern: "a", replacement: "b")
    let before = editor

    #expect(throws: DictionaryEditError.indexOutOfRange) { try editor.updateTerm(at: 1, to: "x") }
    #expect(throws: DictionaryEditError.indexOutOfRange) { try editor.removeTerm(at: -1) }
    #expect(throws: DictionaryEditError.indexOutOfRange) {
      try editor.updateRule(at: 1, pattern: "x", replacement: "y")
    }
    #expect(throws: DictionaryEditError.indexOutOfRange) { try editor.removeRule(at: 1) }
    #expect(editor == before)
  }

  @Test("TXT-03: 既存の辞書から編集を始められる")
  func startsFromExistingDictionary() throws {
    let dictionary = try UserDictionary(
      terms: [DictionaryTerm("utter")], rules: [ReplacementRule(pattern: "a", replacement: "b")])

    let editor = DictionaryEditor(dictionary: dictionary)

    #expect(editor.dictionary == dictionary)
  }

  @Test("TXT-03: エラーの文字列表現に入力値を含めない")
  mutating func errorsDoNotContainInput() throws {
    try editor.addTerm("ひみつのごい")
    do {
      try editor.addTerm("ひみつのごい")
      Issue.record("重複を拒否していない")
    } catch {
      #expect(!String(describing: error).contains("ひみつ"))
      #expect(!String(reflecting: error).contains("ひみつ"))
    }
  }
}
