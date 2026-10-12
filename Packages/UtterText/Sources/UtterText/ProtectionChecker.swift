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
  /// - 整形後にコードとして囲まれた場合も保持とみなすため、整形後のコードの中身も照合する
  /// - 整形後に、整形前のどれにも対応しない同じ種類の保護対象があれば、出現順に組にして `altered` とする
  public func violations(original: String, refined: String) -> [ProtectionViolation] {
    var candidates = extractor.extract(from: refined).flatMap { span in
      [Candidate(span: span, isTopLevel: true)]
        + extractor.extract(from: span.codeContent).map { Candidate(span: $0, isTopLevel: false) }
    }

    var unmatched: [ProtectedSpan] = []
    for span in extractor.extract(from: original) {
      if let index = candidates.firstIndex(where: { !$0.isUsed && $0.key == span.key }) {
        candidates[index].isUsed = true
      } else {
        unmatched.append(span)
      }
    }

    var replacements = candidates.filter { $0.isTopLevel && !$0.isUsed }.map(\.span)
    return unmatched.map { span in
      guard let index = replacements.firstIndex(where: { $0.kind == span.kind }) else {
        return ProtectionViolation(original: span, change: .missing)
      }
      let replacement = replacements.remove(at: index)
      return ProtectionViolation(original: span, change: .altered(to: replacement.text))
    }
  }

  private struct Candidate {
    let span: ProtectedSpan
    let isTopLevel: Bool
    var isUsed = false

    var key: SpanKey { span.key }
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

extension ProtectionViolation: CustomStringConvertible {
  /// 発話本文をログに出さないよう、種類と変化の種別だけを表す。
  public var description: String {
    let change =
      switch change {
      case .missing: "missing"
      case .altered: "altered"
      }
    return "ProtectionViolation(kind: \(original.kind), change: \(change))"
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

  /// コードの囲みを除いた中身。コード以外は空文字。
  fileprivate var codeContent: String {
    switch kind {
    case .codeBlock: String(text.dropFirst(3).dropLast(3))
    case .inlineCode: String(text.dropFirst().dropLast())
    case .url, .dictionaryTerm, .number: ""
    }
  }

  /// 全角の数字と小数点・桁区切りを半角にする。
  private static func normalizingNumber(_ text: String) -> String {
    String(
      text.map { character -> Character in
        switch character {
        case "．": "."
        case "，": ","
        case "０"..."９":
          Character(
            UnicodeScalar(
              character.unicodeScalars.first!.value - 0xFF10 + 0x30)!)
        default: character
        }
      })
  }
}
