import Testing

@testable import UtterEvaluation

struct NumeralNormalizerTests {
  @Test(
    "AC-04: 位取りの漢数字を値として読む",
    arguments: [
      ("三百二十", "320"),
      ("千円", "1000円"),
      ("二万五千", "25000"),
      ("一億二千三百四十五万六千七百八十九", "123456789"),
      ("三兆", "3000000000000"),
      ("十万人", "100000人"),
    ])
  func readsPositionalKanji(_ input: String, _ expected: String) {
    #expect(NumeralNormalizer.convert(input) == expected)
  }

  @Test(
    "AC-04: アラビア数字と位取りの文字の混在を値として読む",
    arguments: [
      ("2千円", "2000円"),
      ("3万円", "30000円"),
      ("300万", "3000000"),
      ("1万2000", "12000"),
      ("1億2000万", "120000000"),
      ("1,200万", "12000000"),
    ])
  func readsMixedNumerals(_ input: String, _ expected: String) {
    #expect(NumeralNormalizer.convert(input) == expected)
  }

  @Test("AC-04: 同じ数の異なる表記は同じ結果になる")
  func equivalentForms() {
    let forms = ["三万円", "3万円", "30000円", "30,000円"]

    #expect(Set(forms.map(NumeralNormalizer.convert)) == ["30000円"])
  }

  @Test(
    "AC-04: 位取りのない数字は1文字ずつ置き換える",
    arguments: [("二〇二六", "2026"), ("零", "0"), ("2026年", "2026年"), ("一般", "1般")])
  func replacesDigitsOneByOne(_ input: String, _ expected: String) {
    #expect(NumeralNormalizer.convert(input) == expected)
  }

  @Test(
    "AC-04: 位取りの文字だけの並びは直後が助数詞のときだけ数として読む",
    arguments: [
      ("十時", "10時"),
      ("百円", "100円"),
      ("千葉", "千葉"),
      ("百合", "百合"),
      ("十", "十"),
    ])
  func readsUnitOnlyRunBeforeCounter(_ input: String, _ expected: String) {
    #expect(NumeralNormalizer.convert(input) == expected)
  }

  @Test(
    "AC-04: 並びの先頭の万・億・兆は数に含めない",
    arguments: [("万一", "万1"), ("万全", "万全"), ("億", "億"), ("兆し", "兆し")])
  func keepsLeadingLargeUnits(_ input: String, _ expected: String) {
    #expect(NumeralNormalizer.convert(input) == expected)
  }

  @Test(
    "AC-04: 3桁ごとでないカンマは桁区切りとみなさない",
    arguments: [("1,2,3", "1,2,3"), ("1,2345", "1,2345"), ("1,000", "1000"), (",000", ",000")])
  func onlyThreeDigitGroupsAreSeparators(_ input: String, _ expected: String) {
    #expect(NumeralNormalizer.convert(input) == expected)
  }

  @Test("AC-04: 数字以外の文字はそのまま残す")
  func keepsSurroundingText() {
    #expect(NumeralNormalizer.convert("会議は三時から五人で") == "会議は3時から5人で")
  }

  @Test("AC-04: 桁あふれする並びは変えない")
  func keepsOverflowingRun() {
    let input = String(repeating: "九", count: 10) + "兆" + String(repeating: "九", count: 10) + "兆"
    #expect(NumeralNormalizer.convert(input) == input)
  }

  @Test("AC-04: 空文字は空文字のまま")
  func emptyString() {
    #expect(NumeralNormalizer.convert("").isEmpty)
  }
}
