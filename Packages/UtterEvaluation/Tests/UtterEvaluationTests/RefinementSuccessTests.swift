import Testing

@testable import UtterEvaluation

struct RefinementSuccessTests {
  private static func fillersRemoved(_ fillers: [String], _ reference: String, _ refined: String)
    -> Bool
  {
    RefinementSuccess(fillers: fillers, selfCorrections: [])
      .fillersRemoved(reference: reference, refined: refined)
  }

  private static func selfCorrected(
    _ corrections: [(String, String)], _ reference: String, _ refined: String
  ) -> Bool {
    RefinementSuccess(
      fillers: [],
      selfCorrections: corrections.map { SelfCorrection(retracted: $0.0, corrected: $0.1) }
    ).selfCorrected(reference: reference, refined: refined)
  }

  @Test(
    "AC-04: フィラーが整形結果に残らなければ成功（正規化してから照合する）",
    arguments: ["明日は3時に集合です。", "明日は、三時に集合です", "あしたは３時に集合です"])
  func fillersRemoved(_ refined: String) {
    #expect(Self.fillersRemoved(["えー", "あのー"], "えー、明日は、あのー、三時に集合です", refined))
  }

  @Test(
    "AC-04: フィラーが1つでも残れば失敗",
    arguments: ["えー明日は3時に集合です", "明日は、あのー、3時に集合です", "明日は3時に集合です、えー"])
  func fillerLeft(_ refined: String) {
    #expect(!Self.fillersRemoved(["えー", "あのー"], "えー、明日は、あのー、三時に集合です", refined))
  }

  @Test("AC-04: 正解のフィラー以外の箇所に同じ文字列があれば、その回数までは残ってよい")
  func fillerTextUsedElsewhere() {
    #expect(Self.fillersRemoved(["あの"], "あの、あの人に送って", "あの人に送って。"))
    #expect(!Self.fillersRemoved(["あの"], "あの、あの人に送って", "あの、あの人に送って。"))
  }

  @Test("AC-04: 同じフィラーが複数回あれば回数分の注釈で数える")
  func repeatedFillers() {
    let reference = "えー、これは、えー、テストです"

    #expect(Self.fillersRemoved(["えー", "えー"], reference, "これはテストです"))
    #expect(!Self.fillersRemoved(["えー", "えー"], reference, "これは、えー、テストです"))
    // 注釈が1件なら、2回目は発話の一部とみなして残ってよい
    #expect(Self.fillersRemoved(["えー"], reference, "これは、えー、テストです"))
  }

  @Test(
    "AC-04: 他のフィラーを含むフィラーは長い順に照合し、短い方を二重に数えない",
    arguments: [
      ("えー、はい", false), ("えーと、はい", false), ("はい", true), ("えー、えーと、はい", false),
    ])
  func overlappingFillers(_ refined: String, _ expected: Bool) {
    #expect(Self.fillersRemoved(["えー", "えーと"], "えー、えーと、はい", refined) == expected)
  }

  @Test("AC-04: 言い直す前の語が残らず、後の語が残れば自己訂正の成功")
  func selfCorrected() {
    #expect(Self.selfCorrected([("三時", "四時")], "会議は三時、いや四時からです", "会議は4時からです。"))
    #expect(Self.selfCorrected([("三時", "四時")], "会議は三時、いや四時からです", "会議は、いや4時からです"))
  }

  @Test(
    "AC-04: 言い直す前の語が残るか、後の語が残らなければ自己訂正の失敗",
    arguments: ["会議は3時からです。", "会議は3時、いや4時からです", "会議は3時か4時からです", "会議からです"])
  func selfCorrectionFailed(_ refined: String) {
    #expect(!Self.selfCorrected([("三時", "四時")], "会議は三時、いや四時からです", refined))
  }

  @Test("AC-04: 言い直す前の語と後の語が重なっても判定できる")
  func overlappingCorrection() {
    let reference = "四時、じゃなくて四時半に集合"

    #expect(Self.selfCorrected([("四時", "四時半")], reference, "4時半に集合"))
    #expect(!Self.selfCorrected([("四時", "四時半")], reference, "4時、4時半に集合"))
    #expect(!Self.selfCorrected([("四時", "四時半")], reference, "4時に集合"))
    #expect(Self.selfCorrected([("四時半", "四時")], "四時半、いや四時に集合", "4時に集合"))
    #expect(!Self.selfCorrected([("四時半", "四時")], "四時半、いや四時に集合", "4時半に集合"))
  }

  @Test(
    "AC-04: 連続した言い直しでは、途中の語は残さなくてよく、最後の語だけを残す",
    arguments: [("緑", true), ("青、緑", false), ("赤、緑", false), ("青", false)])
  func chainedCorrection(_ refined: String, _ expected: Bool) {
    #expect(
      Self.selfCorrected([("赤", "青"), ("青", "緑")], "赤、じゃなくて青、いや緑", refined) == expected)
  }

  @Test("AC-04: 言い直した後の語がフィラーと同じ語でも、フィラーの件数では残すべき件数を減らさない")
  func correctedSameAsFiller() {
    let success = RefinementSuccess(
      fillers: ["えー"], selfCorrections: [SelfCorrection(retracted: "赤", corrected: "えー")])
    let reference = "えー、赤、いやえー"

    #expect(success.missingWords(in: reference) == (fillers: false, selfCorrections: false))
    #expect(success.selfCorrected(reference: reference, refined: "えー"))
    #expect(!success.selfCorrected(reference: reference, refined: "はい"))
  }

  @Test("AC-04: 注釈の語が正解に足りなければ不備として示す")
  func missingWords() {
    let fillers = RefinementSuccess(fillers: ["えー", "えー"], selfCorrections: [])
    let partOfCorrected = RefinementSuccess(
      fillers: [], selfCorrections: [SelfCorrection(retracted: "四時", corrected: "四時半")])
    let chained = RefinementSuccess(
      fillers: [],
      selfCorrections: [
        SelfCorrection(retracted: "赤", corrected: "青"),
        SelfCorrection(retracted: "青", corrected: "緑"),
      ])

    #expect(fillers.missingWords(in: "えー、はい") == (fillers: true, selfCorrections: false))
    #expect(fillers.missingWords(in: "えー、えー、はい") == (fillers: false, selfCorrections: false))
    // 前の語が後の語の一部にしか現れない
    #expect(partOfCorrected.missingWords(in: "四時半です") == (fillers: false, selfCorrections: true))
    #expect(chained.missingWords(in: "赤、じゃなくて青、いや緑") == (fillers: false, selfCorrections: false))
  }

  @Test("AC-04: 出現回数は正規化してから長い語を先に、重ならずに数える")
  func occurrences() {
    let success = RefinementSuccess(fillers: ["ああ", "えー", "えーと"], selfCorrections: [])

    #expect(success.occurrences(in: "あああ")["ああ"] == 1)
    #expect(success.occurrences(in: "えー、えーと")["えー"] == 1)
    #expect(success.occurrences(in: "えー、えーと")["えーと"] == 1)
    #expect(success.occurrences(in: "はい").isEmpty)
  }
}
