import Testing

@testable import UtterEvaluation

struct TermAccuracyTests {
  @Test("AC-04: 正解に含まれる用語が表記どおり出たかを数える")
  func countsExactTerms() {
    let count = TermAccuracy.count(
      terms: ["SwiftUI", "Xcode"],
      reference: "SwiftUI の画面を Xcode で開く",
      hypothesis: "スイフトUI の画面を Xcode で開く")

    #expect(count == ErrorCount(errors: 1, total: 2))
    #expect(count.accuracy == 0.5)
  }

  @Test("AC-04: 用語は大文字・小文字と全角・半角を区別する", arguments: ["swiftui", "ＳｗｉｆｔＵＩ", "Swift UI"])
  func termsAreCaseAndWidthSensitive(_ hypothesis: String) {
    let count = TermAccuracy.count(terms: ["SwiftUI"], reference: "SwiftUI", hypothesis: hypothesis)

    #expect(count == ErrorCount(errors: 1, total: 1))
  }

  @Test("AC-04: 正解に複数回ある用語は回数で数え、多く出ても正解の回数を上限とする")
  func countsOccurrences() {
    let missingOne = TermAccuracy.count(
      terms: ["API"], reference: "API と API", hypothesis: "API とエーピーアイ")
    let extra = TermAccuracy.count(
      terms: ["API"], reference: "API を呼ぶ", hypothesis: "API API API を呼ぶ")

    #expect(missingOne == ErrorCount(errors: 1, total: 2))
    #expect(extra == ErrorCount(errors: 0, total: 1))
  }

  @Test("AC-04: 重複した用語の指定と空の用語は数えない")
  func ignoresDuplicateAndEmptyTerms() {
    let count = TermAccuracy.count(terms: ["Git", "Git", ""], reference: "Git", hypothesis: "Git")

    #expect(count == ErrorCount(errors: 0, total: 1))
  }

  @Test("AC-04: 英数字の用語は単語の一部としての出現を数えない")
  func termsMustBeDelimited() {
    let count = TermAccuracy.count(
      terms: ["Git", "GitHub"], reference: "Git と GitHub", hypothesis: "Git と Gitlab")

    #expect(count == ErrorCount(errors: 1, total: 2))
  }

  @Test(
    "AC-04: 重ならない出現回数を数える",
    arguments: [
      ("ああ", "あああ", 1), ("ab", "ab ab", 2), ("abc", "ab", 0), ("", "abc", 0),
      ("Git", "GitHub", 0), ("Hub", "GitHub", 0), ("View", "View。", 1), ("用語", "専門用語集", 1),
    ])
  func occurrences(_ term: String, _ text: String, _ expected: Int) {
    #expect(TermAccuracy.occurrences(of: term, in: text) == expected)
  }
}
