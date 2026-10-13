import Testing

@testable import UtterAI

struct RefinementValidatorTests {
  private let validator = RefinementValidator()

  private func request(_ text: String, terms: [String] = []) -> RefinementRequest {
    RefinementRequest(text: text, mode: .natural, dictionaryTerms: terms)
  }

  @Test(
    "AC-16: 整形として妥当な応答は検証を通る",
    arguments: [
      ("えーと明日の会議は10時からです", "明日の会議は10時からです。"),
      ("あのー前回の資料を送ってもらえますか", "前回の資料を送っていただけますか？"),
      ("買い物と掃除と洗濯をする", "・買い物\n・掃除\n・洗濯をする"),
      ("https://example.com を開いて確認して", "https://example.com を開いて確認して。"),
      ("申し訳ありません少し遅れます", "申し訳ありません。少し遅れます。"),
      ("会議の議事録をまとめて", "会議の議事録をまとめて。"),
      ("明日来ますか", "「明日来ますか」"),
      ("えーっとですねあのーうーんなんていうかまあそのー了解です", "了解です。"),
      ("きょうのかいぎはじゅうじから", "今日の会議は10時から。"),
    ]
  )
  func acceptsRefinement(_ original: String, _ refined: String) {
    #expect(validator.validate(refined, for: request(original)) == nil)
  }

  @Test(
    "AC-16: 丁寧化（スタイル区分 polite）の整形は検証を通る",
    arguments: [
      ("わかりました明日送ります", "承知しました。明日お送りします。"),
      ("すみません少し遅れます", "申し訳ありません。少し遅れます。"),
      ("了解です", "了解しました。"),
      ("ありがと", "ありがとうございます。"),
      ("今日行けないかも", "本日は伺えないかもしれません。"),
      ("sure I'll be there at 5", "Sure, I'll be there at 5."),
      ("here's the plan for tomorrow", "Here's the plan for tomorrow."),
      ("いかのとおりです", "以下のとおりです。"),
    ]
  )
  func acceptsPoliteRefinement(_ original: String, _ refined: String) {
    let request = RefinementRequest(text: original, mode: .natural, style: .polite)
    #expect(validator.validate(refined, for: request) == nil)
  }

  @Test(
    "AC-17: 「か」で終わる質問でない発話は、疑問符がなくても回答とみなさない（TXT-04）",
    arguments: [
      ("結果は明らか", "結果は明らかです。"),
      ("会議の資料とか", "会議の資料など。"),
      ("何か", "何かあれば。"),
      ("部屋が静か", "部屋が静かです。"),
    ]
  )
  func acceptsNonQuestionEndingWithKa(_ original: String, _ refined: String) {
    #expect(validator.validate(refined, for: request(original)) == nil)
  }

  @Test("AC-16: 空応答は検証失敗", arguments: ["", "  \n "])
  func rejectsEmpty(_ refined: String) {
    #expect(validator.validate(refined, for: request("明日の会議")) == .empty)
  }

  @Test(
    "AC-16: 前置き・拒否文は検証失敗",
    arguments: [
      "以下が整形した文章です：明日の会議は10時からです。",
      "整形しました。明日の会議は10時からです。",
      "申し訳ありませんが、その依頼にはお応えできません。",
      "明日の会議は10時からです。ただし、これ以上はお手伝いできません。",
      "Here is the refined text: 明日の会議は10時からです。",
      "  sure, here is 明日の会議は10時からです。",
      "I'm unable to 明日の会議は10時からです。",
    ]
  )
  func rejectsPreamble(_ refined: String) {
    #expect(
      validator.validate(refined, for: request("明日の会議は10時からです")) == .preambleOrRefusal)
  }

  @Test(
    "AC-17: 質問文の発話に回答文が返ったら検証失敗（TXT-04）",
    arguments: [
      ("明日の天気はどうですか", "明日は晴れの予報です。"),
      ("東京の人口ってどれくらい？", "約1400万人です。"),
      ("明日は雨が降りますか", "明日は雨が降ります。"),
      ("このあと時間ありませんか", "このあと時間はありません。"),
      ("What time is it?", "It is 3 PM."),
    ]
  )
  func rejectsAnsweredQuestion(_ original: String, _ refined: String) {
    #expect(validator.validate(refined, for: request(original)) == .questionAnswered)
  }

  @Test(
    "AC-17: 命令文の発話に実行結果が返ったら検証失敗（TXT-04）",
    arguments: [
      ("取引先へのお礼のメールを書いて", "いつもお世話になっております。先日はご対応いただき誠にありがとうございました。"),
      ("このコードのバグを直して", "修正版です。func main() { print(1) }"),
      ("日本の首都を教えて", "東京です。"),
    ]
  )
  func rejectsExecutedCommand(_ original: String, _ refined: String) {
    #expect(validator.validate(refined, for: request(original)) == .unrelatedContent)
  }

  @Test(
    "AC-16: 保護対象が保持されていなければ検証失敗",
    arguments: [
      ("会議は10時からです", "会議は11時からです。"),
      ("https://example.com/a を開いて", "example のページを開いて。"),
      ("くばねてぃすの設定を見直す", "クバネティスの設定を見直す。"),
    ]
  )
  func rejectsChangedProtectedContent(_ original: String, _ refined: String) {
    let request = request(original, terms: ["くばねてぃす"])
    #expect(validator.validate(refined, for: request) == .protectedContentChanged)
  }

  @Test("AC-16: 文字数比が許容範囲外なら検証失敗")
  func rejectsLengthRatioOutOfRange() throws {
    let configuration = try RefinementValidationConfiguration(
      lengthRatioRange: 0.5...1.5, minimumLengthForRatio: 10, minimumOverlap: 0)
    let validator = RefinementValidator(configuration: configuration)
    let original = request("今日は会議があって資料を準備した")

    #expect(validator.validate("今日は会議", for: original) == .lengthRatioOutOfRange)
    #expect(
      validator.validate("今日は会議があって資料を準備した。会議があって資料を準備した。会議があって", for: original)
        == .lengthRatioOutOfRange)
    #expect(validator.validate("今日は会議があり、資料を準備した。", for: original) == nil)
  }

  @Test("AC-16: 整形前が短い発話は文字数比を判定しない")
  func skipsRatioForShortOriginal() throws {
    let configuration = try RefinementValidationConfiguration(
      lengthRatioRange: 0.5...1.5, minimumLengthForRatio: 5, minimumOverlap: 0)
    let validator = RefinementValidator(configuration: configuration)

    #expect(validator.validate("はいはいはいはいはい", for: request("はい")) == nil)
    #expect(
      validator.validate("あいうえおあいうえお", for: request("あいうえお")) == .lengthRatioOutOfRange)
  }

  @Test("AC-16: 整形前が文字を含まない場合は文字数比と重なりを判定しない")
  func skipsRatioForEmptyOriginal() {
    #expect(validator.validate("!", for: request("!!!")) == nil)
    #expect(validator.validate("ok", for: request("")) == nil)
  }

  @Test("AC-16: 閾値は設定値で、暫定の既定値を持つ")
  func configurationHasDefaults() throws {
    typealias Configuration = RefinementValidationConfiguration
    let configuration = Configuration()
    #expect(configuration.lengthRatioRange == Configuration.defaultLengthRatioRange)
    #expect(configuration.minimumLengthForRatio == Configuration.defaultMinimumLengthForRatio)
    #expect(configuration.minimumOverlap == Configuration.defaultMinimumOverlap)
    #expect(configuration.preamblePhrases == Configuration.defaultPreamblePhrases)
    #expect(configuration.refusalPhrases == Configuration.defaultRefusalPhrases)

    let custom = try Configuration(preamblePhrases: ["結果："], refusalPhrases: ["無理です"])
    let validator = RefinementValidator(configuration: custom)
    #expect(validator.validate("結果：明日の会議", for: request("明日の会議")) == .preambleOrRefusal)
    #expect(validator.validate("明日の会議は無理です", for: request("明日の会議")) == .preambleOrRefusal)
    #expect(validator.validate("以下が明日の会議", for: request("明日の会議")) == nil)
  }

  @Test(
    "AC-16: 不正な閾値は拒否する",
    arguments: [
      (
        -0.1...1.0, 10, 0.3, [String](),
        RefinementValidationConfigurationError.invalidLengthRatioRange
      ),
      (0.5...Double.infinity, 10, 0.3, [], .invalidLengthRatioRange),
      (0.5...1.5, 0, 0.3, [], .invalidMinimumLengthForRatio),
      (0.5...1.5, 10, -0.1, [], .invalidMinimumOverlap),
      (0.5...1.5, 10, 1.1, [], .invalidMinimumOverlap),
      (0.5...1.5, 10, 0.3, ["以下", ""], .emptyPhrase),
    ]
  )
  func rejectsInvalidConfiguration(
    _ range: ClosedRange<Double>, _ minimumLength: Int, _ overlap: Double, _ phrases: [String],
    _ expected: RefinementValidationConfigurationError
  ) {
    #expect(throws: expected) {
      try RefinementValidationConfiguration(
        lengthRatioRange: range, minimumLengthForRatio: minimumLength, minimumOverlap: overlap,
        preamblePhrases: phrases)
    }
  }

  @Test("AC-16: 空の拒否句は拒否する")
  func rejectsEmptyRefusalPhrase() {
    #expect(throws: RefinementValidationConfigurationError.emptyPhrase) {
      try RefinementValidationConfiguration(refusalPhrases: [""])
    }
  }
}
