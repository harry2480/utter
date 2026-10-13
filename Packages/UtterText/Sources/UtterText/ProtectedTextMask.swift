/// 保護対象（TXT-02）を1文字の目印に置き換え、整形の規則が中身を変えられないようにする。
///
/// 目印には補助私用領域 A（U+F0000〜）の文字を使う。整形後に `unmask(_:)` で元の文字列に戻す。
struct ProtectedTextMask: Sendable {
  private static let firstPlaceholder: UInt32 = 0xF0000
  private static let lastPlaceholder: UInt32 = 0xFFFFD

  /// 目印に置き換えたテキスト
  let text: String
  /// 目印の番号ごとの、元の保護対象
  private let spans: [ProtectedSpan]

  /// 入力が目印と同じ範囲の文字を含む、または保護対象が多すぎて目印が足りない場合は `nil`。
  init?(_ original: String, extractor: ProtectedSpanExtractor) {
    guard !original.unicodeScalars.contains(where: Self.isPlaceholder) else { return nil }
    let spans = extractor.extract(from: original).filter { !$0.range.isEmpty }
    guard spans.count <= Int(Self.lastPlaceholder - Self.firstPlaceholder) + 1 else { return nil }

    var masked = ""
    var index = original.startIndex
    for (number, span) in spans.enumerated() {
      masked += original[index..<span.range.lowerBound]
      masked.unicodeScalars.append(Self.placeholder(number))
      index = span.range.upperBound
    }
    masked += original[index...]
    text = masked
    self.spans = spans
  }

  /// 目印を元の保護対象に戻す。
  func unmask(_ masked: String) -> String {
    var result = ""
    for character in masked {
      if let span = span(for: character) {
        result += span.text
      } else {
        result.append(character)
      }
    }
    return result
  }

  /// 目印なら、その保護対象の種類を返す。
  func kind(of character: Character) -> ProtectedSpan.Kind? {
    span(for: character)?.kind
  }

  /// 目印なら `true`。
  static func isPlaceholder(_ character: Character) -> Bool {
    character.unicodeScalars.count == 1 && isPlaceholder(character.unicodeScalars.first!)
  }

  private static func isPlaceholder(_ scalar: Unicode.Scalar) -> Bool {
    (firstPlaceholder...lastPlaceholder).contains(scalar.value)
  }

  private static func placeholder(_ number: Int) -> Unicode.Scalar {
    Unicode.Scalar(firstPlaceholder + UInt32(number))!
  }

  private func span(for character: Character) -> ProtectedSpan? {
    guard Self.isPlaceholder(character) else { return nil }
    let number = Int(character.unicodeScalars.first!.value - Self.firstPlaceholder)
    return spans.indices.contains(number) ? spans[number] : nil
  }
}
