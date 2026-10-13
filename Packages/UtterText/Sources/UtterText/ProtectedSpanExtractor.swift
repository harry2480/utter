/// テキストから保護対象を抽出する（TXT-02）。
///
/// 4つ以上のバッククォートによる囲みや、二重バッククォートのインラインコードは対象外。
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
      dictionaryTerms.flatMap { term in
        text.ranges(of: term).filter { Self.isDelimited($0, in: text) }
      }
    case .number:
      text.matches(of: Self.number).map { Self.trimmingAttachedSign($0.range, in: text) }
    }
  }

  // Regex は Sendable ではないため static 定数にせず、使うたびに生成する
  private static var codeBlock: Regex<Substring> { #/```.*?```/#.dotMatchesNewlines() }
  private static var inlineCode: Regex<Substring> { #/`[^`\n]+`/# }
  // URL に使える ASCII 文字のみ。日本語が直後に続いても URL に含めない
  private static var url: Regex<Substring> { #/https?://[A-Za-z0-9\-._~:/?\[\]@!$&'()*+,;=%#]+/# }
  // 符号つき。`,` は3桁ごとの桁区切りのときだけ数字に含め、`1,2,3` のような列挙は分ける
  private static var number: Regex<Substring> {
    #/[+\-−－＋]?(?:[0-9０-９]{1,3}(?:[,，][0-9０-９]{3})+(?![0-9０-９])|[0-9０-９]+)(?:[.．][0-9０-９]+)*/#
  }

  /// 文末の句読点・Markdown の強調記号と、対応する開き括弧のない `)` `]` を URL から除く。
  private static func trimmingURLSuffix(
    _ range: Range<String.Index>, in text: String
  ) -> Range<String.Index> {
    var url = text[range]
    while let last = url.last {
      let isUnbalanced =
        (last == ")" && url.count(where: { $0 == ")" }) > url.count(where: { $0 == "(" }))
        || (last == "]" && url.count(where: { $0 == "]" }) > url.count(where: { $0 == "[" }))
      guard ".,;:!?'*_".contains(last) || isUnbalanced else { break }
      url.removeLast()
    }
    return url.startIndex..<url.endIndex
  }

  /// `v2-3` の `-` のように英数字の直後にある記号は、符号ではなく区切りとして範囲から除く。
  private static func trimmingAttachedSign(
    _ range: Range<String.Index>, in text: String
  ) -> Range<String.Index> {
    guard let first = text[range].first, !first.isNumber, range.lowerBound > text.startIndex,
      text[text.index(before: range.lowerBound)].isASCIIAlphanumericOrDigit
    else { return range }
    return text.index(after: range.lowerBound)..<range.upperBound
  }

  /// 英数字で始まる・終わる辞書語は、隣も英数字なら単語の一部とみなして一致させない（`Go` と `Google`）。
  static func isDelimited(_ range: Range<String.Index>, in text: String) -> Bool {
    let term = text[range]
    if let first = term.first, first.isASCIIAlphanumericOrDigit, range.lowerBound > text.startIndex,
      text[text.index(before: range.lowerBound)].isASCIIAlphanumericOrDigit
    {
      return false
    }
    if let last = term.last, last.isASCIIAlphanumericOrDigit, range.upperBound < text.endIndex,
      text[range.upperBound].isASCIIAlphanumericOrDigit
    {
      return false
    }
    return true
  }
}

extension Character {
  /// ASCII の英数字、または全角数字
  var isASCIIAlphanumericOrDigit: Bool {
    (isASCII && (isLetter || isNumber)) || ("０"..."９").contains(self)
  }
}
