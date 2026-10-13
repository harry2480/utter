import Testing

@testable import UtterEvaluation

struct CharacterErrorRateTests {
  @Test("AC-04: 正規化してから文字誤りを数える")
  func countsAfterNormalization() {
    let count = CharacterErrorRate().count(reference: "明日、三時に集合。", hypothesis: "明日 3時に集合")

    #expect(count == ErrorCount(errors: 0, total: 7))
    #expect(count.errorRate == 0)
  }

  @Test("AC-04: 分母は正規化後の正解の文字数")
  func denominatorIsNormalizedReferenceLength() {
    let count = CharacterErrorRate().count(reference: "今日は、晴れ。", hypothesis: "今日は雨")

    #expect(count == ErrorCount(errors: 2, total: 5))
    #expect(count.errorRate == 0.4)
  }

  @Test("AC-04: 挿入が多いと CER は 1 を超える")
  func cerCanExceedOne() {
    let count = CharacterErrorRate().count(reference: "はい", hypothesis: "はいそうですね")

    #expect(count.errorRate == 2.5)
  }

  @Test("AC-04: 誤り数は合算してから率を求める")
  func aggregatesBeforeRate() {
    let total = ErrorCount(errors: 1, total: 10) + ErrorCount(errors: 3, total: 10)

    #expect(total == ErrorCount(errors: 4, total: 20))
    #expect(total.errorRate == 0.2)
    #expect(total.accuracy == 0.8)
  }

  @Test("AC-04: 分母が 0 なら率は出さない")
  func zeroDenominatorHasNoRate() {
    #expect(ErrorCount.zero.errorRate == nil)
    #expect(ErrorCount.zero.accuracy == nil)
  }
}
