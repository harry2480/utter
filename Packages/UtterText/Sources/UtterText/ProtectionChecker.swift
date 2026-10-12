/// 整形前の保護対象が整形後にも保持されているかを判定する（TXT-02, 4.1節）。
public struct ProtectionChecker: Sendable {
  public let extractor: ProtectedSpanExtractor

  public init(extractor: ProtectedSpanExtractor = ProtectedSpanExtractor()) {
    self.extractor = extractor
  }

  public init(dictionaryTerms: [String]) {
    self.init(extractor: ProtectedSpanExtractor(dictionaryTerms: dictionaryTerms))
  }

  /// 整形前の保護対象のうち、整形後に同じ種類・同じ内容で見つからないものを出現順に返す。
  ///
  /// - 数字は全角・半角の違いを同一とみなす。漢数字や桁区切りの有無は別の値として扱う
  /// - 整形後にコードとして囲まれた値や、辞書の表記に揃えられて辞書語の一部になった数字も保持とみなす。
  ///   URL の一部になった数字は保持とみなさない
  /// - 整形後に、整形前のどれにも対応しない同じ種類の保護対象があれば、出現順に組にして `altered` とする
  /// - 整形後に追加された保護対象や、出現順の入れ替えは検出しない
  public func violations(original: String, refined: String) -> [ProtectionViolation] {
    var candidates = extractor.extract(from: refined).map { Candidate(span: $0, parent: nil) }
    var unmatched = consume(extractor.extract(from: original), from: &candidates)

    // 整形前のどれとも一致しなかったコード・辞書語の中身だけを照合する。
    // 一致済みのコードの中身を使うと、コードの外で変わった同じ値を見逃すため
    let unusedCount = candidates.count
    for index in 0..<unusedCount where !candidates[index].isUsed {
      candidates += nestedSpans(in: candidates[index].span).map {
        Candidate(span: $0, parent: index)
      }
    }
    unmatched = consume(unmatched, from: &candidates)

    var replacements = replacementOrder(candidates)
    return unmatched.map { span in
      guard let index = replacements.firstIndex(where: { $0.kind == span.kind }) else {
        return ProtectionViolation(original: span, change: .missing)
      }
      let replacement = replacements.remove(at: index)
      return ProtectionViolation(original: span, change: .altered(to: replacement.text))
    }
  }

  /// `spans` を `candidates` と照合し、一致した候補を使用済みにして、一致しなかった `spans` を返す。
  private func consume(_ spans: [ProtectedSpan], from candidates: inout [Candidate])
    -> [ProtectedSpan]
  {
    spans.filter { span in
      guard let index = candidates.firstIndex(where: { !$0.isUsed && $0.span.key == span.key })
      else {
        return true
      }
      candidates[index].isUsed = true
      if let parent = candidates[index].parent {
        candidates[parent].isUsed = true
      }
      return false
    }
  }

  private func nestedSpans(in span: ProtectedSpan) -> [ProtectedSpan] {
    switch span.kind {
    case .codeBlock:
      extractor.extract(from: String(span.text.dropFirst(3).dropLast(3)))
    case .inlineCode:
      extractor.extract(from: String(span.text.dropFirst().dropLast()))
    case .dictionaryTerm:
      // 辞書語自身に一致しないよう、辞書なしで数字などを取り出す
      ProtectedSpanExtractor().extract(from: span.text)
    case .url, .number:
      []
    }
  }

  /// 未使用の候補を整形後の出現順に並べる。中身の候補は親の直後に置く。
  private func replacementOrder(_ candidates: [Candidate]) -> [ProtectedSpan] {
    candidates.indices.filter { candidates[$0].parent == nil }.flatMap { parent in
      ([parent] + candidates.indices.filter { candidates[$0].parent == parent })
        .filter { !candidates[$0].isUsed }
        .map { candidates[$0].span }
    }
  }

  private struct Candidate {
    let span: ProtectedSpan
    /// コード・辞書語の中身から取り出した候補なら、その親の位置
    let parent: Int?
    var isUsed = false
  }
}

/// 保持されていなかった保護対象。
public struct ProtectionViolation: Hashable, Sendable {
  public enum Change: Hashable, Sendable {
    /// 整形後に見つからない
    case missing
    /// 整形後に別の内容へ変わっている
    case altered(to: String)
  }

  /// 整形前のテキスト上の保護対象
  public let original: ProtectedSpan
  public let change: Change

  public init(original: ProtectedSpan, change: Change) {
    self.original = original
    self.change = change
  }
}

// 発話本文をログに出さないよう、文字列表現とリフレクションには種類と変化の種別だけを出す。
extension ProtectionViolation: CustomStringConvertible {
  public var description: String {
    "ProtectionViolation(kind: \(original.kind), change: \(change))"
  }
}

extension ProtectionViolation.Change: CustomStringConvertible, CustomReflectable {
  public var description: String {
    switch self {
    case .missing: "missing"
    case .altered: "altered"
    }
  }

  public var customMirror: Mirror {
    Mirror(self, children: [])
  }
}

private struct SpanKey: Hashable {
  let kind: ProtectedSpan.Kind
  let text: String
}

extension ProtectedSpan {
  fileprivate var key: SpanKey {
    SpanKey(kind: kind, text: kind == .number ? Self.normalizingNumber(text) : text)
  }

  /// 全角の数字・小数点・桁区切り・符号を半角にする。
  private static func normalizingNumber(_ text: String) -> String {
    String(
      text.map { character -> Character in
        switch character {
        case "．": "."
        case "，": ","
        case "−", "－": "-"
        case "＋": "+"
        case "０"..."９":
          Character(
            UnicodeScalar(
              character.unicodeScalars.first!.value - 0xFF10 + 0x30)!)
        default: character
        }
      })
  }
}
