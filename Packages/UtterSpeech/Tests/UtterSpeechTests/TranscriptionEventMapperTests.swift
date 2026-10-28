import Testing

@testable import UtterSpeech

struct TranscriptionEventMapperTests {
  private typealias Run = TranscriptionSegment.Run

  private static func volatile(_ runs: [Run], end: Double) -> TranscriptionSegment {
    TranscriptionSegment(isFinal: false, runs: runs, end: end)
  }

  private static func final(_ runs: [Run], end: Double) -> TranscriptionSegment {
    TranscriptionSegment(isFinal: true, runs: runs, end: end)
  }

  @Test("REC-06: 暫定結果は partial、確定結果は confirmed にする")
  func mapsVolatileAndFinal() {
    var mapper = TranscriptionEventMapper()

    #expect(mapper.map(Self.volatile([Run(text: "あした", start: 0)], end: 0.8)) == [.partial("あした")])
    #expect(
      mapper.map(Self.final([Run(text: "明日は", start: 0), Run(text: "晴れ", start: 0.5)], end: 1.2))
        == [.confirmed("明日は晴れ")])
  }

  @Test("REC-06: 確定テキストは区切りを足さずに連結する")
  func concatenatesConfirmedText() {
    var mapper = TranscriptionEventMapper()

    _ = mapper.map(Self.final([Run(text: "明日は", start: 0)], end: 1))
    _ = mapper.map(Self.volatile([Run(text: "はれ", start: 1)], end: 1.5))
    _ = mapper.map(Self.final([Run(text: "晴れです。", start: 1)], end: 2))

    #expect(mapper.confirmedText == "明日は晴れです。")
  }

  @Test("2.2節: 確定した範囲より後の暫定部分が残っていれば、confirmed の後に partial で送り直す")
  func resendsRemainingVolatile() {
    var mapper = TranscriptionEventMapper()
    _ = mapper.map(
      Self.volatile(
        [Run(text: "明日は", start: 0), Run(text: "晴れ", start: 1.0), Run(text: "です", start: 1.5)],
        end: 2))

    let kinds = mapper.map(Self.final([Run(text: "明日は", start: 0)], end: 1.0))

    #expect(kinds == [.confirmed("明日は"), .partial("晴れです")])
    // 送り直した残りが次の確定で消えることも確かめる
    #expect(mapper.map(Self.final([Run(text: "晴れです", start: 1.0)], end: 2)) == [.confirmed("晴れです")])
  }

  @Test("2.2節: 送り直す残りの途中にある時刻のない部分（単語の間の空白など）も残す")
  func keepsUntimedRunsInsideRemainder() {
    var mapper = TranscriptionEventMapper()
    _ = mapper.map(
      Self.volatile(
        [
          Run(text: "hello", start: 0), Run(text: " ", start: nil), Run(text: "world", start: 1),
          Run(text: " ", start: nil), Run(text: "again", start: 1.5),
        ], end: 2))

    let kinds = mapper.map(Self.final([Run(text: "hello ", start: 0)], end: 1))

    #expect(kinds == [.confirmed("hello "), .partial("world again")])
  }

  @Test("2.2節: 確定した範囲にかかる暫定部分は送り直さない")
  func dropsVolatileOverlappingFinal() {
    var mapper = TranscriptionEventMapper()
    _ = mapper.map(
      Self.volatile([Run(text: "明日は", start: 0), Run(text: "晴れ", start: 0.9)], end: 1.6))

    #expect(mapper.map(Self.final([Run(text: "明日は", start: 0)], end: 1.0)) == [.confirmed("明日は")])
  }

  @Test("2.2節: 時刻の丸め程度の差なら、確定した範囲の直後の部分として送り直す")
  func toleratesRoundingAtBoundary() {
    var mapper = TranscriptionEventMapper()
    _ = mapper.map(
      Self.volatile([Run(text: "a", start: 0), Run(text: "b", start: 0.9995)], end: 1.5))

    #expect(
      mapper.map(Self.final([Run(text: "a", start: 0)], end: 1.0)) == [
        .confirmed("a"), .partial("b"),
      ])
  }

  @Test("2.2節: 時刻の属性がない暫定部分は送り直さない")
  func doesNotResendWithoutTimeRange() {
    var mapper = TranscriptionEventMapper()
    _ = mapper.map(Self.volatile([Run(text: "明日は晴れ", start: nil)], end: 2))

    #expect(mapper.map(Self.final([Run(text: "明日は", start: nil)], end: 1)) == [.confirmed("明日は")])
  }

  @Test("2.2節: 暫定結果がない状態の確定結果は confirmed だけ")
  func finalWithoutVolatile() {
    var mapper = TranscriptionEventMapper()
    _ = mapper.map(Self.volatile([Run(text: "a", start: 1.5)], end: 2))
    _ = mapper.map(Self.final([Run(text: "a", start: 1.5)], end: 2))

    // 直前の確定で暫定結果は消えているため、古い暫定部分を送り直さない
    #expect(mapper.map(Self.final([Run(text: "b", start: 2)], end: 3)) == [.confirmed("b")])
  }

  @Test("REC-06: 空の暫定結果は空の partial にする（表示中の暫定テキストを消す）")
  func mapsEmptyVolatile() {
    var mapper = TranscriptionEventMapper()

    #expect(mapper.map(Self.volatile([], end: 1)) == [.partial("")])
  }

  @Test("#48: 確定されないまま残った末尾の暫定結果は completedText の末尾に含める")
  func completedTextKeepsUnfinalizedTail() {
    var mapper = TranscriptionEventMapper()
    _ = mapper.map(Self.final([Run(text: "明日は", start: 0)], end: 1))
    _ = mapper.map(Self.volatile([Run(text: "晴れです", start: 1)], end: 2))

    #expect(mapper.confirmedText == "明日は")
    #expect(mapper.completedText == "明日は晴れです")
  }

  @Test("#48: 確定結果がないまま終わったら、最後の暫定結果を completedText にする")
  func completedTextWithoutFinal() {
    var mapper = TranscriptionEventMapper()
    _ = mapper.map(Self.volatile([Run(text: "あした", start: 0)], end: 0.8))
    _ = mapper.map(Self.volatile([Run(text: "明日は晴れ", start: 0)], end: 1.5))

    #expect(mapper.completedText == "明日は晴れ")
  }

  @Test("#48: 暫定結果が後から確定として出し直されたら、確定だけを使い二重にしない")
  func completedTextDoesNotDuplicateFinalizedVolatile() {
    var mapper = TranscriptionEventMapper()
    _ = mapper.map(Self.final([Run(text: "明日は", start: 0)], end: 1))
    _ = mapper.map(Self.volatile([Run(text: "はれです", start: 1)], end: 2))
    _ = mapper.map(Self.final([Run(text: "晴れです。", start: 1)], end: 2))

    #expect(mapper.completedText == "明日は晴れです。")
  }

  @Test("#48: 確定が暫定結果の一部だけをカバーしたら、確定した範囲より後の部分だけを足す")
  func completedTextAppendsOnlyUncoveredRuns() {
    var mapper = TranscriptionEventMapper()
    _ = mapper.map(
      Self.volatile(
        [Run(text: "明日は", start: 0), Run(text: "晴れ", start: 1.0), Run(text: "です", start: 1.5)],
        end: 2))
    _ = mapper.map(Self.final([Run(text: "明日は", start: 0)], end: 1.0))

    #expect(mapper.completedText == "明日は晴れです")
  }

  @Test("#48: 確定した範囲に収まる暫定結果は足さない")
  func completedTextSkipsVolatileInsideFinalizedRange() {
    var mapper = TranscriptionEventMapper()
    _ = mapper.map(Self.final([Run(text: "明日は晴れ", start: 0)], end: 2))
    _ = mapper.map(Self.volatile([Run(text: "晴れ", start: 1)], end: 2))

    #expect(mapper.completedText == "明日は晴れ")
  }

  @Test("#48: 時刻の属性がない場合は、最後の確定の後に届いた暫定結果を足す")
  func completedTextUsesLatestVolatileWithoutTimeRange() {
    var mapper = TranscriptionEventMapper()
    _ = mapper.map(Self.volatile([Run(text: "明日は晴れ", start: nil)], end: 2))
    _ = mapper.map(Self.final([Run(text: "明日は", start: nil)], end: 1))
    // 確定の前に届いた属性のない暫定結果は、確定でカバーされたかを判断できないため足さない
    #expect(mapper.completedText == "明日は")

    _ = mapper.map(Self.volatile([Run(text: "はれ", start: nil)], end: 1.6))
    _ = mapper.map(Self.volatile([Run(text: "晴れです", start: nil)], end: 2.2))
    #expect(mapper.completedText == "明日は晴れです")
  }

  @Test("#48: 確定結果だけなら completedText は確定テキストと同じ")
  func completedTextEqualsConfirmedWithoutVolatile() {
    var mapper = TranscriptionEventMapper()
    _ = mapper.map(Self.final([Run(text: "明日は", start: 0)], end: 1))
    _ = mapper.map(Self.final([Run(text: "晴れ", start: 1)], end: 2))

    #expect(mapper.completedText == mapper.confirmedText)
    #expect(mapper.completedText == "明日は晴れ")
  }

  @Test("#48: 空・空白だけの暫定結果は completedText に足さない")
  func completedTextSkipsEmptyVolatile() {
    var empty = TranscriptionEventMapper()
    _ = empty.map(Self.final([Run(text: "明日は", start: 0)], end: 1))
    _ = empty.map(Self.volatile([], end: 1.5))
    var blank = TranscriptionEventMapper()
    _ = blank.map(Self.final([Run(text: "明日は", start: 0)], end: 1))
    _ = blank.map(Self.volatile([Run(text: " ", start: 1)], end: 1.5))

    #expect(empty.completedText == "明日は")
    #expect(blank.completedText == "明日は")
  }

  @Test("REC-06: 文字列表現に認識テキストを含めない")
  func descriptionsHideText() {
    var mapper = TranscriptionEventMapper()
    let segment = Self.final([Run(text: "秘密の発話", start: 0)], end: 1)
    _ = mapper.map(segment)

    for text in [
      String(describing: segment), String(reflecting: segment), String(describing: mapper),
      String(reflecting: mapper),
    ] {
      #expect(!text.contains("秘密"))
    }
  }
}
