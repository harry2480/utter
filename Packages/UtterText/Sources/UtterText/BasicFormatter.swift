/// ネットワークを使わないルールベースの整形（Local Basic, AI-03, TXT-01, TXT-02）。
///
/// - Natural: フィラーの除去、空白と句読点の補正
/// - Structured: Natural に加えて、列挙を箇条書きに、話題の切り替えを段落に分ける
///
/// 数字・URL・コード・辞書語は目印に置き換えてから規則を適用するため変わらない。
/// 規則は語を除く・空白と句読点を整える・改行と箇条書きの記号を足すことだけで、入力にない語を足さない。
/// 発話が質問や命令でも、回答や実行はせずに整形した文を返す（TXT-04）。クラウド AI と同等の自然さは保証しない。
public struct BasicFormatter: Sendable {
  public struct Options: Hashable, Sendable {
    /// 日本語で終わる文の末尾に「。」を補う。チャットやターミナル向けには `false` にする
    public var addsSentenceEnd: Bool

    public init(addsSentenceEnd: Bool = true) {
      self.addsSentenceEnd = addsSentenceEnd
    }
  }

  public let extractor: ProtectedSpanExtractor
  public let options: Options

  public init(dictionaryTerms: [String] = [], options: Options = Options()) {
    extractor = ProtectedSpanExtractor(dictionaryTerms: dictionaryTerms)
    self.options = options
  }

  /// Natural モードの整形（TXT-01, TXT-02）。
  public func natural(_ text: String) -> String {
    format(text) { masked, _ in naturalize(masked) }
  }

  /// Structured モードの整形（TXT-01）。
  ///
  /// 「まず」「次に」などで始まる文が2つ以上あれば、その文から始まる部分を箇条書きにする。
  /// そうでなければ「ところで」「さて」などで始まる文の前で段落を分ける。
  public func structured(_ text: String) -> String {
    format(text) { masked, mask in
      let sentences = Self.sentences(in: naturalize(masked))
      let isMarker = { (sentence: String) in Self.startsWithListMarker(sentence, mask: mask) }
      if sentences.count(where: isMarker) >= 2 {
        return Self.bulletList(sentences, isMarker: isMarker)
      }
      return Self.paragraphs(sentences)
    }
  }

  /// 保護対象を目印に置き換えて `transform` を適用し、元に戻す。目印を使えない入力は空白の除去だけ行う。
  private func format(
    _ text: String, _ transform: (String, ProtectedTextMask) -> String
  ) -> String {
    guard let mask = ProtectedTextMask(text, extractor: extractor) else {
      return Self.trimmingWhitespace(text)
    }
    return mask.unmask(transform(mask.text, mask))
  }

  private func naturalize(_ text: String) -> String {
    var result = Self.normalizingSpaces(text)
    result = Self.removingFillers(result)
    result = Self.correctingPunctuation(result)
    if options.addsSentenceEnd {
      result = Self.addingSentenceEnds(result)
    }
    return result
  }
}

// MARK: - 空白

extension BasicFormatter {
  /// 行ごとに、連続する空白を1つにまとめ、日本語どうしの間と日本語の句読点の前後の空白を除く。
  static func normalizingSpaces(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false)
      .map { normalizingSpaces(inLine: Array($0)) }
      .joined(separator: "\n")
  }

  private static func normalizingSpaces(inLine line: [Character]) -> String {
    var result: [Character] = []
    var index = 0
    while index < line.count {
      guard line[index].isWhitespace else {
        result.append(line[index])
        index += 1
        continue
      }
      var end = index
      while end < line.count, line[end].isWhitespace {
        end += 1
      }
      // 行頭・行末の空白と、日本語の文字・句読点に接する空白は除く。英単語の間などは1つにまとめる
      if let previous = result.last, end < line.count,
        !(previous.isJapaneseOrPunctuation && line[end].isJapaneseOrPunctuation),
        !previous.isJapanesePunctuation, !line[end].isJapanesePunctuation
      {
        result.append(" ")
      }
      index = end
    }
    return String(result)
  }

  static func trimmingWhitespace(_ text: String) -> String {
    String(text.drop(while: \.isWhitespace).reversed().drop(while: \.isWhitespace).reversed())
  }
}

// MARK: - フィラー

extension BasicFormatter {
  /// 除去するフィラー（TXT-02）。長いものから照合する。
  ///
  /// 「あの」「その」「まあ」のように指示語や副詞として意味を持つ語は、長音つきの形だけを対象にする。
  static let fillers: [String] = [
    "えーっと", "えーと", "えっと", "ええと", "えー",
    "あのー", "あの〜", "そのー", "その〜",
    "うーんと", "うーん", "んー",
    "umm", "uhm", "um", "uh",
  ].sorted { $0.count > $1.count }

  /// 文頭・空白・句読点の直後にあるフィラーを、後に続く長音・空白・読点ごと除く。
  static func removingFillers(_ text: String) -> String {
    let characters = Array(text)
    var result: [Character] = []
    var index = 0
    while index < characters.count {
      let atBoundary = result.last.map { $0.isWhitespace || $0.isSentencePunctuation } ?? true
      if atBoundary, let end = fillerEnd(in: characters, at: index) {
        index = end
        while index < characters.count,
          characters[index].isWhitespace || characters[index] == "、" || characters[index] == ","
        {
          index += 1
        }
        continue
      }
      result.append(characters[index])
      index += 1
    }
    return String(result)
  }

  /// `index` から始まるフィラーの終端。フィラーでなければ `nil`。
  private static func fillerEnd(in characters: [Character], at index: Int) -> Int? {
    for filler in fillers {
      let candidate = Array(filler)
      guard index + candidate.count <= characters.count,
        zip(characters[index...], candidate).allSatisfy({ $0.lowercased() == String($1) })
      else { continue }
      var end = index + candidate.count
      while end < characters.count, "ー〜~".contains(characters[end]) {
        end += 1
      }
      // 英語のフィラーは単語の途中（"umbrella" など）では除かない
      if candidate.allSatisfy(\.isASCII), end < characters.count, characters[end].isLetter {
        continue
      }
      return end
    }
    return nil
  }
}

// MARK: - 句読点

extension BasicFormatter {
  /// 連続した句読点を1つにまとめ、文末記号の直前の読点と、行頭の句読点を除く。
  static func correctingPunctuation(_ text: String) -> String {
    var result: [Character] = []
    for character in text {
      if character.isComma || character == "。" {
        // 行頭・同じ記号の連続・文末記号の後の読点は除く
        guard let previous = result.last, previous != "\n" else { continue }
        if previous == character || (character.isComma && previous.isSentenceEnd) {
          continue
        }
      }
      if character.isSentenceEnd, let previous = result.last, previous.isComma {
        result.removeLast()
      }
      result.append(character)
    }
    // 行末の読点は除く
    return String(result).split(separator: "\n", omittingEmptySubsequences: false)
      .map { line in
        var line = Substring(line)
        while let last = line.last, last.isComma || last.isWhitespace {
          line.removeLast()
        }
        return String(line)
      }
      .joined(separator: "\n")
  }

  /// 日本語の文字で終わる行の末尾に「。」を補う。
  static func addingSentenceEnds(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false)
      .map { line in
        guard let last = line.last, last.isJapanese else { return String(line) }
        return line + "。"
      }
      .joined(separator: "\n")
  }
}

// MARK: - 文・箇条書き・段落

extension BasicFormatter {
  /// 箇条書きの始まりとみなす語（TXT-01）。
  static let listMarkers = [
    "まず", "最初に", "はじめに", "初めに", "次に", "それから", "続いて", "さらに", "最後に",
    "第一に", "第二に", "第三に", "一つ目", "二つ目", "三つ目", "四つ目", "五つ目",
    "ひとつ目", "ふたつ目", "みっつ目",
  ]
  /// 数字の後に続くと箇条書きの始まりとみなす語（「1つ目」「2番目」など）
  static let numberedListSuffixes = ["つ目", "番目", "点目", "個目"]
  /// 段落の始まりとみなす語（TXT-01）
  static let paragraphMarkers = ["ところで", "さて", "一方", "それでは", "では"]

  /// 文末記号（と直後の閉じ括弧）と改行で文に分ける。空の文は除く。
  static func sentences(in text: String) -> [String] {
    var sentences: [String] = []
    var current = ""
    let characters = Array(text)
    var index = 0
    while index < characters.count {
      let character = characters[index]
      if character == "\n" {
        sentences.append(current)
        current = ""
        index += 1
        continue
      }
      current.append(character)
      index += 1
      if character.isSentenceEnd {
        while index < characters.count, characters[index].isClosingBracket {
          current.append(characters[index])
          index += 1
        }
        sentences.append(current)
        current = ""
      }
    }
    sentences.append(current)
    return sentences.map(trimmingWhitespace).filter { !$0.isEmpty }
  }

  static func startsWithListMarker(_ sentence: String, mask: ProtectedTextMask) -> Bool {
    if listMarkers.contains(where: sentence.hasPrefix) {
      return true
    }
    guard let first = sentence.first, mask.kind(of: first) == .number else { return false }
    let rest = sentence.dropFirst()
    return numberedListSuffixes.contains(where: rest.hasPrefix)
  }

  /// 最初の箇条書きより前の文は導入の段落とし、箇条書きの後に続く文はその項目に含める。
  static func bulletList(_ sentences: [String], isMarker: (String) -> Bool) -> String {
    var introduction: [String] = []
    var items: [[String]] = []
    for sentence in sentences {
      if isMarker(sentence) {
        items.append([sentence])
      } else if items.isEmpty {
        introduction.append(sentence)
      } else {
        items[items.count - 1].append(sentence)
      }
    }
    let lines = items.map { "- " + joiningSentences($0) }
    guard !introduction.isEmpty else { return lines.joined(separator: "\n") }
    return joiningSentences(introduction) + "\n" + lines.joined(separator: "\n")
  }

  /// 段落の始まりとみなす語で始まる文の前で段落を分ける。
  static func paragraphs(_ sentences: [String]) -> String {
    var paragraphs: [[String]] = []
    for sentence in sentences {
      if paragraphs.isEmpty || paragraphMarkers.contains(where: sentence.hasPrefix) {
        paragraphs.append([sentence])
      } else {
        paragraphs[paragraphs.count - 1].append(sentence)
      }
    }
    return paragraphs.map(joiningSentences).joined(separator: "\n\n")
  }

  /// 文をつなげる。日本語の文末の後には空白を入れず、それ以外は空白で区切る。
  static func joiningSentences(_ sentences: [String]) -> String {
    var result = ""
    for sentence in sentences {
      if let last = result.last, !last.isJapaneseOrPunctuation {
        result += " "
      }
      result += sentence
    }
    return result
  }
}

// MARK: - 文字の分類

extension Character {
  /// ひらがな・カタカナ・漢字・長音記号・繰り返し記号
  fileprivate var isJapanese: Bool {
    guard let scalar = unicodeScalars.first else { return false }
    switch scalar.value {
    case 0x3040...0x309F, 0x30A0...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
      0xFF66...0xFF9F, 0x3005, 0x3006:
      return true
    default:
      return false
    }
  }

  /// 和文の句読点・括弧・全角記号
  fileprivate var isJapanesePunctuation: Bool {
    guard let scalar = unicodeScalars.first else { return false }
    switch scalar.value {
    case 0x3000...0x3004, 0x3007...0x303F, 0xFF01...0xFF0F, 0xFF1A...0xFF20, 0xFF3B...0xFF40,
      0xFF5B...0xFF65:
      return true
    default:
      return false
    }
  }

  fileprivate var isJapaneseOrPunctuation: Bool {
    isJapanese || isJapanesePunctuation
  }

  /// 文末記号
  fileprivate var isSentenceEnd: Bool {
    "。．！？!?".contains(self)
  }

  /// 読点
  fileprivate var isComma: Bool {
    "、，,".contains(self)
  }

  /// フィラーの直前とみなす句読点
  fileprivate var isSentencePunctuation: Bool {
    isSentenceEnd || isComma || isClosingBracket || "「『（(".contains(self)
  }

  fileprivate var isClosingBracket: Bool {
    "」』）)】".contains(self)
  }
}
