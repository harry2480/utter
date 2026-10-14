import Testing

@testable import UtterEvaluation

struct TextNormalizerTests {
  @Test(
    "AC-04: 句読点・括弧・ダッシュ・空白・不可視の書式文字を除く",
    arguments: [
      ("今日は、晴れです。", "今日は晴れです"),
      ("「はい」と言った！", "はいと言った"),
      ("Hello, world?", "helloworld"),
      ("改行\nと\tタブ", "改行とタブ"),
      ("Wi-Fi・LAN", "wifilan"),
      ("a\u{200B}b\u{FEFF}", "ab"),
    ])
  func removesPunctuationAndWhitespace(_ input: String, _ expected: String) {
    #expect(TextNormalizer().normalize(input) == expected)
  }

  @Test(
    "AC-04: 全角・半角をそろえる",
    arguments: [("ＳｗｉｆｔＵＩ", "swiftui"), ("１２３", "123"), ("ｶﾀｶﾅ", "カタカナ")])
  func normalizesWidth(_ input: String, _ expected: String) {
    #expect(TextNormalizer().normalize(input) == expected)
  }

  @Test("AC-04: 英字の大文字・小文字をそろえる")
  func lowercasesLatin() {
    #expect(TextNormalizer().normalize("GitHub API") == "githubapi")
  }

  @Test(
    "AC-04: 意味を持つ記号は残す",
    arguments: [
      ("コーヒー", "コーヒー"),
      ("C++", "c++"),
      ("C#", "c#"),
      ("50%", "50%"),
      ("a/b", "a/b"),
      ("a@b", "a@b"),
    ])
  func keepsMeaningfulSymbols(_ input: String, _ expected: String) {
    #expect(TextNormalizer().normalize(input) == expected)
  }

  @Test(
    "AC-04: 数字に挟まれた小数点と時刻のコロンは残す",
    arguments: [("1.5", "1.5"), ("3:00", "3:00"), ("終わり.", "終わり"), ("v1.", "v1")])
  func keepsDecimalPointAndTimeColon(_ input: String, _ expected: String) {
    #expect(TextNormalizer().normalize(input) == expected)
  }

  @Test("AC-04: 波ダッシュと全角チルダはどちらも除く")
  func removesTildes() {
    let normalizer = TextNormalizer()

    #expect(normalizer.normalize("3〜5") == "35")
    #expect(normalizer.normalize("3～5") == "35")
  }

  @Test("AC-04: 数字表記をそろえる（漢数字・混在・桁区切り・全角数字）")
  func normalizesNumbers() {
    let normalizer = TextNormalizer()
    let forms = ["千二百円", "1,200円", "１２００円", "1200円", "1千200円"]

    #expect(Set(forms.map(normalizer.normalize)) == ["1200円"])
  }
}
