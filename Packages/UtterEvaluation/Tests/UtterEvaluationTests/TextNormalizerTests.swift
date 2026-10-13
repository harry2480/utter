import Testing

@testable import UtterEvaluation

struct TextNormalizerTests {
  @Test(
    "AC-04: 句読点・括弧・空白を除く",
    arguments: [
      ("今日は、晴れです。", "今日は晴れです"),
      ("「はい」と言った！", "はいと言った"),
      ("Hello, world?", "helloworld"),
      ("改行\nと\tタブ", "改行とタブ"),
    ])
  func removesPunctuationAndWhitespace(_ input: String, _ expected: String) {
    #expect(TextNormalizer().normalize(input) == expected)
  }

  @Test(
    "AC-04: 全角・半角をそろえる",
    arguments: [
      ("ＳｗｉｆｔＵＩ", "swiftui"),
      ("１２３", "123"),
      ("ｶﾀｶﾅ", "カタカナ"),
    ])
  func normalizesWidth(_ input: String, _ expected: String) {
    #expect(TextNormalizer().normalize(input) == expected)
  }

  @Test("AC-04: 英字の大文字・小文字をそろえる")
  func lowercasesLatin() {
    #expect(TextNormalizer().normalize("GitHub API") == "githubapi")
  }

  @Test("AC-04: 長音記号と記号は残す")
  func keepsProlongedSoundMarkAndSymbols() {
    #expect(TextNormalizer().normalize("コーヒー C++") == "コーヒーc++")
  }

  @Test("AC-04: 数字表記をそろえる（漢数字・桁区切り・全角数字）")
  func normalizesNumbers() {
    let normalizer = TextNormalizer()
    let forms = ["千二百円", "1,200円", "１２００円", "1200円"]

    #expect(Set(forms.map(normalizer.normalize)) == ["1200円"])
  }
}
