extension UserDictionary {
  /// 置換ルールを適用したテキストを返す（TXT-03）。
  ///
  /// - 先頭から走査し、各位置で最も長く一致するルールを適用する。置換結果は再置換しない
  /// - 英数字で始まる・終わるパターンは、隣も英数字なら単語の一部とみなして置換しない（`git` と `github`）
  /// - URL・インラインコード・コードブロックの中は置換しない
  public func applyingReplacements(to text: String) -> String {
    guard !rules.isEmpty else { return text }
    let rulesByLength = rules.sorted { $0.pattern.count > $1.pattern.count }
    let protected = ProtectedSpanExtractor().extract(from: text)
      .filter { [.url, .inlineCode, .codeBlock].contains($0.kind) }
      .map(\.range)

    var result = ""
    var index = text.startIndex
    while index < text.endIndex {
      if let range = protected.first(where: { $0.lowerBound == index }) {
        result += text[range]
        index = range.upperBound
        continue
      }
      let match = rulesByLength.lazy.compactMap { rule in
        rule.match(in: text, at: index).map { (rule, $0) }
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
}

extension ReplacementRule {
  /// `index` から始まる一致の範囲。
  fileprivate func match(in text: String, at index: String.Index) -> Range<String.Index>? {
    guard let end = text.index(index, offsetBy: pattern.count, limitedBy: text.endIndex) else {
      return nil
    }
    let candidate = text[index..<end]
    let isEqual =
      ignoresCase ? candidate.lowercased() == pattern.lowercased() : candidate == pattern
    guard isEqual, ProtectedSpanExtractor.isDelimited(index..<end, in: text) else { return nil }
    return index..<end
  }
}
