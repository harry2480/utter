/// 用語単位の正答率（9章、日英混在・開発用語・辞書語）。
///
/// 用語は表記どおりに書かれているかを見るため、CER の正規化を適用せず、
/// 大文字・小文字や全角・半角も区別して照合する。
/// 英数字で始まる・終わる用語は、隣も英数字なら単語の一部とみなして数えない（`Git` と `GitHub`）。
public enum TermAccuracy {
  /// 正解に含まれる各用語について、認識結果に同じ回数以上現れたかを数える。
  ///
  /// 分母は各用語が正解に現れる回数の合計。正解より多く現れても正答は正解の回数までとする。
  public static func count(terms: [String], reference: String, hypothesis: String) -> ErrorCount {
    var result = ErrorCount.zero
    for term in Set(terms) where !term.isEmpty {
      let expected = occurrences(of: term, in: reference)
      let correct = min(expected, occurrences(of: term, in: hypothesis))
      result = result + ErrorCount(errors: expected - correct, total: expected)
    }
    return result
  }

  /// 重ならない出現回数。英数字で始まる・終わる用語は、単語の一部としての出現を数えない。
  static func occurrences(of term: String, in text: String) -> Int {
    let needle = Array(term)
    let haystack = Array(text)
    guard !needle.isEmpty, haystack.count >= needle.count else { return 0 }
    var count = 0
    var index = 0
    while index <= haystack.count - needle.count {
      let end = index + needle.count
      if haystack[index..<end].elementsEqual(needle),
        !(needle[0].isASCIIAlphanumeric && index > 0 && haystack[index - 1].isASCIIAlphanumeric),
        !(needle[needle.count - 1].isASCIIAlphanumeric && end < haystack.count
          && haystack[end].isASCIIAlphanumeric)
      {
        count += 1
        index = end
      } else {
        index += 1
      }
    }
    return count
  }
}

extension Character {
  fileprivate var isASCIIAlphanumeric: Bool {
    isASCII && (isLetter || isNumber)
  }
}
