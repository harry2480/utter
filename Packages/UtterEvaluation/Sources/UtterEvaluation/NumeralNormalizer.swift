/// 数字の表記をアラビア数字にそろえる（9章の数字表記の正規化）。NFKC と小文字化の後に適用する。
///
/// - 漢数字・アラビア数字・位取りの文字（十・百・千・万・億・兆）の並びを1つの数として読む
///   （三百二十 → 320、2千 → 2000、1億2000万 → 120000000）
/// - 位取りの文字を含まない並びは1文字ずつ置き換える（二〇二六 → 2026）
/// - 3桁ごとの桁区切りの `,` は除いて読む（1,200万 → 12000000）
/// - 数字を含まず位取りの文字だけの並び（千葉の千、百合の百）は、直後が助数詞のときだけ数として読む（十時 → 10時）
/// - 並びの先頭の万・億・兆は数に含めない（万一 → 万1）
/// - 桁あふれする並びは変えない
enum NumeralNormalizer {
  private static let kanjiDigits: [Character: Int64] = [
    "〇": 0, "零": 0, "一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9,
  ]
  private static let smallUnits: [Character: Int64] = ["十": 10, "百": 100, "千": 1000]
  private static let largeUnits: [Character: Int64] = [
    "万": 10_000, "億": 100_000_000, "兆": 1_000_000_000_000,
  ]
  /// 位取りの文字だけの並びを数として読むときの、直後の助数詞
  static let counters: Set<Character> = [
    "時", "分", "秒", "円", "人", "個", "回", "年", "月", "日", "歳", "才", "本", "枚", "台", "件",
    "点", "倍", "度", "割", "番", "冊", "杯", "匹", "頭", "名", "階", "週", "%", "代", "位", "号",
  ]

  static func convert(_ text: String) -> String {
    let characters = Array(text)
    var result = ""
    var run: [Character] = []
    for index in characters.indices {
      let character = characters[index]
      if isNumeral(character) {
        run.append(character)
      } else if character == ",", isDigitGroupSeparator(at: index, in: characters) {
        continue
      } else {
        result += convertRun(run, next: character)
        run.removeAll()
        result.append(character)
      }
    }
    result += convertRun(run, next: nil)
    return result
  }

  private static func isNumeral(_ character: Character) -> Bool {
    digit(character) != nil || smallUnits[character] != nil || largeUnits[character] != nil
  }

  private static func digit(_ character: Character) -> Int64? {
    if let value = kanjiDigits[character] {
      return value
    }
    guard character.isASCII, let value = character.wholeNumberValue else { return nil }
    return Int64(value)
  }

  private static func isASCIIDigit(_ character: Character) -> Bool {
    character.isASCII && character.isNumber
  }

  /// 直前がアラビア数字で、直後がちょうど3桁のアラビア数字なら桁区切り。
  private static func isDigitGroupSeparator(at index: Int, in characters: [Character]) -> Bool {
    guard index > 0, isASCIIDigit(characters[index - 1]) else { return false }
    let digits = characters[(index + 1)...].prefix(4).prefix(while: isASCIIDigit)
    return digits.count == 3
  }

  private static func convertRun(_ run: [Character], next: Character?) -> String {
    let leading = run.prefix { largeUnits[$0] != nil }
    return String(leading) + convertBody(Array(run.dropFirst(leading.count)), next: next)
  }

  private static func convertBody(_ run: [Character], next: Character?) -> String {
    guard !run.isEmpty else { return "" }
    if run.allSatisfy({ digit($0) != nil }) {
      return run.map { String(digit($0) ?? 0) }.joined()
    }
    let hasDigit = run.contains { digit($0) != nil }
    guard hasDigit || next.map(counters.contains) == true, let value = positionalValue(run) else {
      return String(run)
    }
    return String(value)
  }

  /// 位取りで読んだ値。桁あふれした場合は `nil`。
  private static func positionalValue(_ run: [Character]) -> Int64? {
    var total: Int64 = 0
    var section: Int64 = 0
    var current: Int64 = 0
    for character in run {
      if let digit = digit(character) {
        guard let shifted = multiply(current, 10), let next = add(shifted, digit) else {
          return nil
        }
        current = next
      } else if let unit = smallUnits[character] {
        guard let value = multiply(current == 0 ? 1 : current, unit), let next = add(section, value)
        else { return nil }
        section = next
        current = 0
      } else if let unit = largeUnits[character] {
        guard let sum = add(section, current),
          let value = multiply(sum == 0 ? 1 : sum, unit),
          let next = add(total, value)
        else { return nil }
        total = next
        section = 0
        current = 0
      }
    }
    guard let sum = add(section, current) else { return nil }
    return add(total, sum)
  }

  private static func multiply(_ lhs: Int64, _ rhs: Int64) -> Int64? {
    let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
    return overflow ? nil : value
  }

  private static func add(_ lhs: Int64, _ rhs: Int64) -> Int64? {
    let (value, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? nil : value
  }
}
