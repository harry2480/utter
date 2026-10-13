import Testing

@testable import UtterText

struct UserDictionaryTests {
  @Test(
    "TXT-03: 読み・誤変換を正しい表記に置換する",
    arguments: [
      ("くーばねてぃすでデプロイ", "Kubernetesでデプロイ"),
      ("ギットハブにプッシュ", "GitHubにプッシュ"),
      ("くーばねてぃすとギットハブ", "KubernetesとGitHub"),
      ("置換対象なし", "置換対象なし"),
      ("", ""),
    ]
  )
  func replacesMisrecognizedTerms(_ text: String, _ expected: String) throws {
    let dictionary = try UserDictionary(rules: [
      ReplacementRule(pattern: "くーばねてぃす", replacement: "Kubernetes"),
      ReplacementRule(pattern: "ギットハブ", replacement: "GitHub"),
    ])

    #expect(dictionary.applyingReplacements(to: text) == expected)
  }

  @Test("TXT-03: 長い一致を優先する（定義順によらない）")
  func prefersLongestMatch() throws {
    let dictionary = try UserDictionary(rules: [
      ReplacementRule(pattern: "スイフト", replacement: "Swift"),
      ReplacementRule(pattern: "スイフトユーアイ", replacement: "SwiftUI"),
    ])

    #expect(dictionary.applyingReplacements(to: "スイフトユーアイとスイフト") == "SwiftUIとSwift")
  }

  @Test("TXT-03: 先に始まる一致を優先する")
  func prefersLeftmostMatch() throws {
    let dictionary = try UserDictionary(rules: [
      ReplacementRule(pattern: "あい", replacement: "X"),
      ReplacementRule(pattern: "いうえ", replacement: "Y"),
    ])

    #expect(dictionary.applyingReplacements(to: "あいうえ") == "Xうえ")
  }

  @Test(
    "TXT-03: 置換結果を再置換しない",
    arguments: [
      ("あい", "いう"),
      ("テスト", "テストテスト"),
    ]
  )
  func doesNotReplaceReplacement(_ text: String, _ expected: String) throws {
    let dictionary = try UserDictionary(rules: [
      ReplacementRule(pattern: "あ", replacement: "い"),
      ReplacementRule(pattern: "い", replacement: "う"),
      ReplacementRule(pattern: "テスト", replacement: "テストテスト"),
    ])

    #expect(dictionary.applyingReplacements(to: text) == expected)
  }

  @Test("TXT-03: 大文字小文字を無視するルールはどの表記にも一致する")
  func ignoresCaseWhenSpecified() throws {
    let dictionary = try UserDictionary(rules: [
      ReplacementRule(pattern: "github", replacement: "GitHub", ignoresCase: true)
    ])

    #expect(
      dictionary.applyingReplacements(to: "Github と GITHUB と github") == "GitHub と GitHub と GitHub")
  }

  @Test("TXT-03: 大文字小文字を区別するルールは同じ表記にだけ一致する")
  func respectsCaseByDefault() throws {
    let dictionary = try UserDictionary(rules: [
      ReplacementRule(pattern: "github", replacement: "GitHub")
    ])

    #expect(dictionary.applyingReplacements(to: "Github と github") == "Github と GitHub")
  }

  @Test(
    "TXT-03: 英字のパターンは単語の一部には一致させない",
    arguments: [
      ("git と github", "Git と github"),
      ("gitで管理", "Gitで管理"),
      ("legit", "legit"),
      ("git2", "git2"),
    ]
  )
  func requiresWordBoundaryForASCIIPattern(_ text: String, _ expected: String) throws {
    let dictionary = try UserDictionary(rules: [
      ReplacementRule(pattern: "git", replacement: "Git", ignoresCase: true)
    ])

    #expect(dictionary.applyingReplacements(to: text) == expected)
  }

  @Test(
    "TXT-03: URL・コードの中は置換しない",
    arguments: [
      ("https://github.com/a と github", "https://github.com/a と GitHub"),
      ("`git clone github` の github", "`git clone github` の GitHub"),
      ("```\ngithub\n```\ngithub", "```\ngithub\n```\nGitHub"),
    ]
  )
  func doesNotReplaceInsideProtectedSpans(_ text: String, _ expected: String) throws {
    let dictionary = try UserDictionary(rules: [
      ReplacementRule(pattern: "github", replacement: "GitHub", ignoresCase: true)
    ])

    #expect(dictionary.applyingReplacements(to: text) == expected)
  }

  @Test("TXT-03: URL・コードにまたがる一致は置換しない")
  func doesNotReplaceAcrossProtectedSpan() throws {
    let dictionary = try UserDictionary(rules: [
      ReplacementRule(pattern: "て`l", replacement: "X"),
      ReplacementRule(pattern: "て", replacement: "テ"),
    ])

    #expect(dictionary.applyingReplacements(to: "見て`ls`") == "見テ`ls`")
  }

  @Test(
    "TXT-03: 最長一致が URL・コードにかかる位置では短いルールを使う",
    arguments: [
      ("見てhttps://a.com", "見テhttps://a.com"),
      ("見て```\nls\n```", "見テ```\nls\n```"),
    ]
  )
  func fallsBackToShorterRuleBeforeProtectedSpan(_ text: String, _ expected: String) throws {
    let dictionary = try UserDictionary(rules: [
      ReplacementRule(pattern: "てh", replacement: "X"),
      ReplacementRule(pattern: "て`", replacement: "X"),
      ReplacementRule(pattern: "て", replacement: "テ"),
    ])

    #expect(dictionary.applyingReplacements(to: text) == expected)
  }

  @Test(
    "TXT-03: 数字で終わるパターンは続く数字と一体なら置換しない",
    arguments: [
      ("GPT 5 を使う", "GPT-5 を使う"),
      ("GPT 50 を使う", "GPT 50 を使う"),
      ("GPT 5.1 を使う", "GPT-5.1 を使う"),
    ]
  )
  func patternEndingWithDigit(_ text: String, _ expected: String) throws {
    let dictionary = try UserDictionary(rules: [
      ReplacementRule(pattern: "GPT 5", replacement: "GPT-5")
    ])

    #expect(dictionary.applyingReplacements(to: text) == expected)
  }

  @Test("TXT-03: 全角数字が続く英字パターンは置換しない")
  func fullWidthDigitIsWordCharacter() throws {
    let dictionary = try UserDictionary(rules: [
      ReplacementRule(pattern: "git", replacement: "Git", ignoresCase: true)
    ])

    #expect(dictionary.applyingReplacements(to: "git１ と git") == "git１ と Git")
  }

  @Test("TXT-03: 結合文字は正規等価で照合し、文字の途中では一致させない")
  func matchesByCanonicalEquivalence() throws {
    let dictionary = try UserDictionary(rules: [
      ReplacementRule(pattern: "が", replacement: "ガ"),
      ReplacementRule(pattern: "て", replacement: "テ"),
    ])

    #expect(dictionary.applyingReplacements(to: "か\u{3099}とて\u{3099}") == "ガとて\u{3099}")
  }

  @Test("TXT-03: 大文字始まりのテキストにも大文字小文字を無視するルールが一致する")
  func ignoresCaseOfFirstCharacter() throws {
    let dictionary = try UserDictionary(rules: [
      ReplacementRule(pattern: "GitHub", replacement: "GitHub", ignoresCase: true),
      ReplacementRule(pattern: "Go", replacement: "Go言語"),
    ])

    #expect(dictionary.applyingReplacements(to: "GITHUB と github と Go") == "GitHub と GitHub と Go言語")
  }

  @Test("TXT-03: 境界は置換前のテキストで判定する")
  func checksBoundaryBeforeReplacement() throws {
    let dictionary = try UserDictionary(rules: [
      ReplacementRule(pattern: "えーと", replacement: ""),
      ReplacementRule(pattern: "github", replacement: "GitHub"),
    ])

    #expect(dictionary.applyingReplacements(to: "gitえーとhub") == "github")
  }

  @Test("TXT-03: 置換後を空にしてフィラーを取り除ける")
  func replacesWithEmptyString() throws {
    let dictionary = try UserDictionary(rules: [
      ReplacementRule(pattern: "えーと、", replacement: "")
    ])

    #expect(dictionary.applyingReplacements(to: "えーと、明日です") == "明日です")
  }

  @Test("TXT-03: ルールがなければテキストを変えない")
  func returnsTextWithoutRules() throws {
    let dictionary = try UserDictionary()

    #expect(
      dictionary.applyingReplacements(to: "https://example.com を見て") == "https://example.com を見て")
  }

  @Test("TXT-03: 空のパターン・空の辞書語は拒否する")
  func rejectsEmptyInput() {
    #expect(throws: UserDictionaryError.emptyPattern) {
      try ReplacementRule(pattern: "", replacement: "X")
    }
    #expect(throws: UserDictionaryError.emptySpelling) {
      try DictionaryTerm("")
    }
  }

  @Test(
    "TXT-03: 同じテキストに一致しうるルールの組は拒否する",
    arguments: [
      (("github", false), ("github", false)),
      (("GitHub", true), ("github", false)),
      (("github", false), ("GITHUB", true)),
      (("GitHub", true), ("gitHUB", true)),
    ]
  )
  func rejectsConflictingRules(_ first: (String, Bool), _ second: (String, Bool)) throws {
    let rules = [
      try ReplacementRule(pattern: "くーばねてぃす", replacement: "Kubernetes"),
      try ReplacementRule(pattern: first.0, replacement: "A", ignoresCase: first.1),
      try ReplacementRule(pattern: second.0, replacement: "B", ignoresCase: second.1),
    ]

    #expect(throws: UserDictionaryError.conflictingRules(first: 1, second: 2)) {
      try UserDictionary(rules: rules)
    }
  }

  @Test("TXT-03: 正規等価なパターンの組は衝突として拒否する")
  func rejectsCanonicallyEquivalentPatterns() throws {
    let rules = [
      try ReplacementRule(pattern: "が", replacement: "A"),
      try ReplacementRule(pattern: "か\u{3099}", replacement: "B"),
    ]

    #expect(throws: UserDictionaryError.conflictingRules(first: 0, second: 1)) {
      try UserDictionary(rules: rules)
    }
  }

  @Test("TXT-03: 長さの違うルールは共存できる")
  func allowsRulesWithDifferentLength() throws {
    let dictionary = try UserDictionary(rules: [
      ReplacementRule(pattern: "git", replacement: "Git", ignoresCase: true),
      ReplacementRule(pattern: "github", replacement: "GitHub", ignoresCase: true),
    ])

    #expect(dictionary.applyingReplacements(to: "git と GitHub") == "Git と GitHub")
  }

  @Test("TXT-03: 表記の異なる大文字小文字を区別するルールは共存できる")
  func allowsCaseSensitiveRulesWithDifferentCase() throws {
    let dictionary = try UserDictionary(rules: [
      ReplacementRule(pattern: "Github", replacement: "GitHub"),
      ReplacementRule(pattern: "github", replacement: "GitHub"),
    ])

    #expect(dictionary.applyingReplacements(to: "Github github") == "GitHub GitHub")
  }

  @Test("TXT-03: 辞書語を保護対象の抽出に渡す")
  func providesExtractorWithTerms() throws {
    let dictionary = try UserDictionary(terms: [
      DictionaryTerm("Kubernetes"), DictionaryTerm("GitHub"),
    ])
    let spans = dictionary.protectedSpanExtractor.extract(from: "Kubernetes を GitHub で管理")

    #expect(spans.map(\.kind) == [.dictionaryTerm, .dictionaryTerm])
    #expect(dictionary.terms.map(\.spelling) == ["Kubernetes", "GitHub"])
  }

  @Test("TXT-03: 検証エラーの説明文字列に利用者の入力を含めない")
  func errorDoesNotContainInput() throws {
    let rules = [
      try ReplacementRule(pattern: "secret-term", replacement: "A"),
      try ReplacementRule(pattern: "secret-term", replacement: "B"),
    ]
    let error = #expect(throws: UserDictionaryError.self) {
      try UserDictionary(rules: rules)
    }

    #expect(!"\(String(describing: error))".contains("secret"))
  }
}
