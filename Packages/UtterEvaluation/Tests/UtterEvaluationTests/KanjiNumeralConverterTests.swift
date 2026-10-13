import Testing

@testable import UtterEvaluation

struct KanjiNumeralConverterTests {
  @Test(
    "AC-04: 位取りの漢数字を値として読む",
    arguments: [
      ("十", "10"),
      ("三百二十", "320"),
      ("千", "1000"),
      ("二万五千", "25000"),
      ("一億二千三百四十五万六千七百八十九", "123456789"),
      ("三兆", "3000000000000"),
      ("十万", "100000"),
    ])
  func readsPositionalNumerals(_ input: String, _ expected: String) {
    #expect(KanjiNumeralConverter.convert(input) == expected)
  }

  @Test(
    "AC-04: 位取りのない漢数字は1文字ずつ置き換える",
    arguments: [("二〇二六", "2026"), ("零", "0"), ("一", "1")])
  func replacesDigitsOneByOne(_ input: String, _ expected: String) {
    #expect(KanjiNumeralConverter.convert(input) == expected)
  }

  @Test("AC-04: 漢数字以外の文字はそのまま残す")
  func keepsSurroundingText() {
    #expect(KanjiNumeralConverter.convert("会議は三時から五人で") == "会議は3時から5人で")
  }

  @Test("AC-04: 万・億・兆だけの並びは変えない", arguments: ["万全", "億", "兆し"])
  func keepsLargeUnitsAlone(_ input: String) {
    #expect(KanjiNumeralConverter.convert(input) == input)
  }

  @Test("AC-04: 桁あふれする並びは変えない")
  func keepsOverflowingRun() {
    let input = String(repeating: "九", count: 10) + "兆" + String(repeating: "九", count: 10) + "兆"
    #expect(KanjiNumeralConverter.convert(input) == input)
  }

  @Test("AC-04: 空文字は空文字のまま")
  func emptyString() {
    #expect(KanjiNumeralConverter.convert("").isEmpty)
  }
}
