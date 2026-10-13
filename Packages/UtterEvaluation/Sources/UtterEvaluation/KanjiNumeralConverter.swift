/// 漢数字の並びをアラビア数字に置き換える（9章の数字表記の正規化）。
///
/// - 位取りの文字（十・百・千・万・億・兆）を含む並びは値として読む（例: 三百二十 → 320、二万五千 → 25000）
/// - 位取りの文字を含まない並びは1文字ずつ置き換える（例: 二〇二六 → 2026）
/// - 万・億・兆だけの並び（例: 「万全」の万）と、桁あふれする並びは変えない
///
/// 「一般」が「1般」になるような語の内部の置き換えも起きるが、正解と認識結果の両方へ同じ規則を適用するため CER には影響しない。
enum KanjiNumeralConverter {
  private static let digits: [Character: Int64] = [
    "〇": 0, "零": 0, "一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9,
  ]
  private static let smallUnits: [Character: Int64] = ["十": 10, "百": 100, "千": 1000]
  private static let largeUnits: [Character: Int64] = [
    "万": 10_000, "億": 100_000_000, "兆": 1_000_000_000_000,
  ]

  static func convert(_ text: String) -> String {
    var result = ""
    var run: [Character] = []
    for character in text {
      if isNumeral(character) {
        run.append(character)
      } else {
        result += convertRun(run)
        run.removeAll()
        result.append(character)
      }
    }
    result += convertRun(run)
    return result
  }

  private static func isNumeral(_ character: Character) -> Bool {
    digits[character] != nil || smallUnits[character] != nil || largeUnits[character] != nil
  }

  private static func convertRun(_ run: [Character]) -> String {
    guard !run.isEmpty else { return "" }
    if run.allSatisfy({ largeUnits[$0] != nil }) {
      return String(run)
    }
    if run.allSatisfy({ digits[$0] != nil }) {
      return run.map { String(digits[$0] ?? 0) }.joined()
    }
    guard let value = positionalValue(run) else {
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
      if let digit = digits[character] {
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
