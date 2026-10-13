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
    /// ターミナル向け。日本語のフィラーの除去と前後の空白の除去だけを行い、
    /// 英語のフィラー・空白の連続・句読点・改行は変えない（CTX-01 のコマンド保護）
    public var preservesCommands: Bool

    public init(addsSentenceEnd: Bool = true, preservesCommands: Bool = false) {
      self.addsSentenceEnd = addsSentenceEnd
      self.preservesCommands = preservesCommands
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
  /// `preservesCommands` のときは Natural と同じにする。
  public func structured(_ text: String) -> String {
    guard !options.preservesCommands else { return natural(text) }
    return format(text) { masked, mask in
      let sentences = Self.sentences(in: naturalize(masked))
      let isMarker = { (sentence: Sentence) in Self.startsWithListMarker(sentence.text, mask: mask)
      }
      if sentences.count(where: isMarker) >= 2 {
        return Self.bulletList(sentences, isMarker: isMarker)
      }
      return Self.paragraphs(sentences)
    }
  }

  /// 保護対象を目印に置き換えて `transform` を適用し、元に戻す。目印を使えない入力は空白の除去だけ行う。
  ///
  /// 末尾の改行がコマンドの実行にならないよう、結果の前後の空白・改行は必ず除く。
  private func format(
    _ text: String, _ transform: (String, ProtectedTextMask) -> String
  ) -> String {
    guard let mask = ProtectedTextMask(text, extractor: extractor) else {
      return Self.trimmingWhitespace(text)
    }
    return Self.trimmingWhitespace(mask.unmask(transform(mask.text, mask)))
  }

  private func naturalize(_ text: String) -> String {
    if options.preservesCommands {
      return Self.removingFillers(text, includesLatin: false)
    }
    var result = Self.normalizingSpaces(text)
    result = Self.removingFillers(result, includesLatin: true)
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
  /// 「あの」「その」のように指示語として意味を持つ語は、長音つきの形だけを対象にする。
  /// 「ええと」は相づちの「ええ」に続く語（ええとても）と区別できないため対象にしない。
  /// 長音つきの指示語に名詞が続く発話（そのー件）は、指示語ごと除かれる（AI-03 の限界）。
  static let fillers: [String] = [
    "えーっと", "えーと", "えっと", "えー",
    "あのー", "あの〜", "そのー", "その〜",
    "うーんと", "うーん", "んー",
  ].sorted { $0.count > $1.count }
  /// 除去する英語のフィラー。小文字か先頭だけ大文字のときに限る（UH などの略語は除かない）
  static let latinFillers: [String] = ["umm", "uhm", "um", "uh"]

  /// 文頭・空白・句読点の直後にあるフィラーを、後に続く長音・空白・読点ごと除く。
  ///
  /// 直後が文末記号・閉じ括弧のもの（えー！、「えー」）は感嘆や引用とみなして除かない。
  static func removingFillers(_ text: String, includesLatin: Bool) -> String {
    let characters = Array(text)
    var result: [Character] = []
    var index = 0
    while index < characters.count {
      let atBoundary = result.last.map { $0.isWhitespace || $0.isFillerBoundary } ?? true
      if atBoundary, let end = fillerEnd(in: characters, at: index, includesLatin: includesLatin) {
        index = end
        while index < characters.count,
          (characters[index].isWhitespace && !characters[index].isNewline)
            || characters[index] == "、" || characters[index] == ","
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
  private static func fillerEnd(
    in characters: [Character], at index: Int, includesLatin: Bool
  ) -> Int? {
    for filler in fillers {
      let candidate = Array(filler)
      guard index + candidate.count <= characters.count,
        characters[index..<(index + candidate.count)].elementsEqual(candidate)
      else { continue }
      var end = index + candidate.count
      while end < characters.count, "ー〜~".contains(characters[end]) {
        end += 1
      }
      guard end == characters.count || !characters[end].isFillerTerminator else { return nil }
      return end
    }
    guard includesLatin else { return nil }
    for filler in latinFillers {
      let end = index + filler.count
      guard end <= characters.count else { continue }
      let word = String(characters[index..<end])
      guard word == filler || word == filler.prefix(1).uppercased() + filler.dropFirst() else {
        continue
      }
      // 単語の途中（umbrella）、ハイフンや省略記号でつながる語（uh-oh, umm...）は除かない
      if end < characters.count,
        characters[end].isLetter || "-'.’".contains(characters[end])
          || characters[end].isFillerTerminator
      {
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
  /// 箇条書きを終えて、続く文を段落にする語
  static let listEndMarkers = paragraphMarkers + ["以上"]

  /// 文と、次の文とのつなぎ方。
  struct Sentence: Hashable {
    let text: String
    /// 次の文との間の区切り。同じ行なら元の空白（空白なしは空文字）、改行で分けたなら `nil`
    let separator: String?
  }

  /// 文末記号（と直後の文末記号・閉じ括弧）と改行で文に分ける。空の文は除く。
  static func sentences(in text: String) -> [Sentence] {
    var sentences: [Sentence] = []
    var current = ""
    func append(atNewline: Bool) {
      let trimmed = trimmingWhitespace(current)
      if !trimmed.isEmpty {
        let separator = current.last?.isWhitespace == true ? " " : ""
        sentences.append(Sentence(text: trimmed, separator: atNewline ? nil : separator))
      } else if atNewline, let last = sentences.last {
        sentences[sentences.count - 1] = Sentence(text: last.text, separator: nil)
      }
      current = ""
    }
    let characters = Array(text)
    var index = 0
    while index < characters.count {
      let character = characters[index]
      if character == "\n" {
        append(atNewline: true)
        index += 1
        continue
      }
      current.append(character)
      index += 1
      if character.isSentenceEnd {
        while index < characters.count,
          characters[index].isSentenceEnd || characters[index].isClosingBracket
        {
          current.append(characters[index])
          index += 1
        }
        // 後に続く空白は、この文の区切りとして記録する
        while index < characters.count, characters[index].isWhitespace, characters[index] != "\n" {
          current.append(" ")
          index += 1
        }
        append(atNewline: false)
      }
    }
    append(atNewline: true)
    return sentences
  }

  /// 列挙の語で始まる文か。語の直後がひらがな（「は」を除く）なら別の語の一部とみなす（まずい、続いている）。
  static func startsWithListMarker(_ sentence: String, mask: ProtectedTextMask) -> Bool {
    for marker in listMarkers where sentence.hasPrefix(marker) {
      let next = sentence.dropFirst(marker.count).first
      if let next, next.isHiragana, next != "は" {
        continue
      }
      return true
    }
    guard let first = sentence.first, mask.kind(of: first) == .number else { return false }
    let rest = sentence.dropFirst()
    return numberedListSuffixes.contains(where: rest.hasPrefix)
  }

  /// 最初の箇条書きより前の文は導入の段落とし、箇条書きの後に続く文はその項目に含める。
  /// 箇条書きの後に「以上」や段落の始まりの語で始まる文が来たら、そこからを締めの段落にする。
  static func bulletList(_ sentences: [Sentence], isMarker: (Sentence) -> Bool) -> String {
    var introduction: [Sentence] = []
    var items: [[Sentence]] = []
    var conclusion: [Sentence] = []
    for sentence in sentences {
      if !conclusion.isEmpty {
        conclusion.append(sentence)
      } else if isMarker(sentence) {
        items.append([sentence])
      } else if items.isEmpty {
        introduction.append(sentence)
      } else if listEndMarkers.contains(where: sentence.text.hasPrefix) {
        conclusion.append(sentence)
      } else {
        items[items.count - 1].append(sentence)
      }
    }
    var blocks = [items.map { "- " + joiningSentences($0) }.joined(separator: "\n")]
    if !introduction.isEmpty {
      blocks.insert(joiningSentences(introduction), at: 0)
    }
    if !conclusion.isEmpty {
      blocks.append("\n" + joiningSentences(conclusion))
    }
    return blocks.joined(separator: "\n")
  }

  /// 段落の始まりとみなす語で始まる文の前で段落を分ける。
  static func paragraphs(_ sentences: [Sentence]) -> String {
    var paragraphs: [[Sentence]] = []
    for sentence in sentences {
      if paragraphs.isEmpty || paragraphMarkers.contains(where: sentence.text.hasPrefix) {
        paragraphs.append([sentence])
      } else {
        paragraphs[paragraphs.count - 1].append(sentence)
      }
    }
    return paragraphs.map(joiningSentences).joined(separator: "\n\n")
  }

  /// 文をつなげる。同じ行の文は元の空白のとおりにつなぎ、改行で分けた文は
  /// 日本語の後なら空白なし、それ以外は空白で区切る。
  static func joiningSentences(_ sentences: [Sentence]) -> String {
    var result = ""
    var separator: String? = ""
    for sentence in sentences {
      if !result.isEmpty {
        if let separator {
          result += separator
        } else if let last = result.last, !last.isJapaneseOrPunctuation {
          result += " "
        }
      }
      result += sentence.text
      separator = sentence.separator
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

  /// フィラーの直前とみなす句読点。開き括弧は引用（「えー」と言った）を残すため含めない
  fileprivate var isFillerBoundary: Bool {
    isSentenceEnd || isComma || isClosingBracket
  }

  /// 直後に来たらフィラーとみなさない文字（感嘆の「えー！」、引用の「えー」）
  fileprivate var isFillerTerminator: Bool {
    isSentenceEnd || isClosingBracket
  }

  fileprivate var isHiragana: Bool {
    guard let scalar = unicodeScalars.first else { return false }
    return (0x3041...0x309F).contains(scalar.value)
  }

  fileprivate var isClosingBracket: Bool {
    "」』）)】".contains(self)
  }
}
