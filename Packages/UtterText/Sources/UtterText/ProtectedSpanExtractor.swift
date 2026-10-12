/// テキストから保護対象を抽出する（TXT-02）。
public struct ProtectedSpanExtractor: Sendable {
  /// 長いものから順に照合する辞書語。空文字と重複は除く。
  public let dictionaryTerms: [String]

  public init(dictionaryTerms: [String] = []) {
    self.dictionaryTerms = Set(dictionaryTerms.filter { !$0.isEmpty })
      .sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
  }

  /// 保護対象を出現順に返す。範囲が重なる候補は `ProtectedSpan.Kind` の宣言順で先の種類を採用する。
  public func extract(from text: String) -> [ProtectedSpan] {
    var spans: [ProtectedSpan] = []
    for kind in ProtectedSpan.Kind.allCases {
      for range in candidates(of: kind, in: text)
      where !spans.contains(where: { $0.range.overlaps(range) }) {
        spans.append(ProtectedSpan(kind: kind, range: range, text: String(text[range])))
      }
    }
    return spans.sorted { $0.range.lowerBound < $1.range.lowerBound }
  }

  private func candidates(of kind: ProtectedSpan.Kind, in text: String) -> [Range<String.Index>] {
    switch kind {
    case .codeBlock:
      text.matches(of: Self.codeBlock).map(\.range)
    case .inlineCode:
      text.matches(of: Self.inlineCode).map(\.range)
    case .url:
      text.matches(of: Self.url).map { Self.trimmingURLSuffix($0.range, in: text) }
    case .dictionaryTerm:
      dictionaryTerms.flatMap { text.ranges(of: $0) }
    case .number:
      text.matches(of: Self.number).map(\.range)
    }
  }

  // Regex は Sendable ではないため static 定数にせず、使うたびに生成する
  private static var codeBlock: Regex<Substring> { #/```.*?```/#.dotMatchesNewlines() }
  private static var inlineCode: Regex<Substring> { #/`[^`\n]+`/# }
  // URL に使える ASCII 文字のみ。日本語が直後に続いても URL に含めない
  private static var url: Regex<Substring> { #/https?://[A-Za-z0-9\-._~:/?\[\]@!$&'()*+,;=%#]+/# }
  private static var number: Regex<Substring> { #/[0-9０-９]+(?:[.,．，][0-9０-９]+)*/# }

  /// 文末の句読点と、対応する `(` のない `)` を URL から除く。
  private static func trimmingURLSuffix(
    _ range: Range<String.Index>, in text: String
  ) -> Range<String.Index> {
    var url = text[range]
    while let last = url.last {
      let isUnbalancedParen =
        last == ")" && url.count(where: { $0 == ")" }) > url.count(where: { $0 == "(" })
      guard ".,;:!?'".contains(last) || isUnbalancedParen else { break }
      url.removeLast()
    }
    return url.startIndex..<url.endIndex
  }
}
