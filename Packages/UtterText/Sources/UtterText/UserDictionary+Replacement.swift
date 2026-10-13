extension UserDictionary {
  /// 置換ルールを適用したテキストを返す（TXT-03）。保護対象の抽出や整形より前に呼ぶ。
  ///
  /// - 先頭から走査し、各位置で最も長く一致するルールを適用する。置換結果は再置換しない
  /// - 英数字で始まる・終わるパターンは、隣も英数字なら単語の一部とみなして置換しない（`git` と `github`）。
  ///   境界は置換前のテキストで判定するため、空文字への置換で前後の英字がつながることがある
  /// - URL・インラインコード・コードブロックの中は置換しない。置換結果が新たにコードや URL になることはある
  public func applyingReplacements(to text: String) -> String {
    guard !rules.isEmpty else { return text }
    let protected = ProtectedSpanExtractor().extract(from: text)
      .filter { [.url, .inlineCode, .codeBlock].contains($0.kind) && !$0.range.isEmpty }
      .map(\.range)

    var result = ""
    var index = text.startIndex
    while index < text.endIndex {
      if let range = protected.first(where: { $0.lowerBound == index }) {
        result += text[range]
        index = range.upperBound
        continue
      }
      let match = matchers(at: text[index]).lazy.compactMap { matcher in
        matcher.match(in: text, at: index).map { (matcher.rule, $0) }
      }.first { _, range in !protected.contains { $0.overlaps(range) } }
      if let (rule, range) = match {
        result += rule.replacement
        index = range.upperBound
      } else {
        result.append(text[index])
        index = text.index(after: index)
      }
    }
    return result
  }

  /// `character` で始まりうるルールを、パターンの長い順に返す。
  private func matchers(at character: Character) -> [ReplacementMatcher] {
    let exact = matchersByFirstCharacter[String(character)] ?? []
    let lowercased = character.lowercased()
    guard lowercased != String(character) else { return exact }
    return (exact + (matchersByFirstCharacter[lowercased] ?? [])).sorted { $0.length > $1.length }
  }
}

/// 照合用に前処理した置換ルール。
struct ReplacementMatcher: Hashable, Sendable {
  let rule: ReplacementRule
  /// パターンの文字数
  let length: Int
  /// 照合に使うパターン。大文字小文字を無視するルールでは小文字にしたもの
  let comparablePattern: String

  init(_ rule: ReplacementRule) {
    self.rule = rule
    length = rule.pattern.count
    comparablePattern = rule.ignoresCase ? rule.pattern.lowercased() : rule.pattern
  }

  /// 振り分けに使う先頭文字。大文字小文字を無視するルールでは小文字にしたもの
  var firstCharacterKey: String {
    rule.pattern.first.map { rule.ignoresCase ? $0.lowercased() : String($0) } ?? ""
  }

  /// `index` から始まる一致の範囲。
  func match(in text: String, at index: String.Index) -> Range<String.Index>? {
    guard let end = text.index(index, offsetBy: length, limitedBy: text.endIndex) else {
      return nil
    }
    let candidate = text[index..<end]
    let isEqual =
      rule.ignoresCase
      ? candidate.lowercased() == comparablePattern : candidate == comparablePattern
    guard isEqual, ProtectedSpanExtractor.isDelimited(index..<end, in: text) else { return nil }
    return index..<end
  }
}
