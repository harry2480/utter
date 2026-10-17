import Testing

@testable import UtterText

struct TextDiffTests {
  let differ = TextDiffer()

  private func pairs(_ diff: TextDiff) -> [(TextDiffSegment.Kind, String)] {
    diff.segments.map { ($0.kind, $0.text) }
  }

  /// 動的計画法で求めた最長共通部分列の長さ（最短性の検査用）。
  private static func lcsLength(_ a: [Character], _ b: [Character]) -> Int {
    guard !b.isEmpty else { return 0 }
    var row = [Int](repeating: 0, count: b.count + 1)
    for x in a {
      var diagonal = 0
      for j in 1...b.count {
        let above = row[j]
        row[j] = x == b[j - 1] ? diagonal + 1 : max(row[j], row[j - 1])
        diagonal = above
      }
    }
    return row[b.count]
  }

  /// 固定シードの線形合同法。テストの入力を決定的に作る。
  private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
      state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return state
    }
  }

  @Test("AC-14: 同じテキストは変更なしの1区間になる")
  func identicalTexts() {
    let diff = differ.diff(from: "会議は3時からです", to: "会議は3時からです")

    #expect(pairs(diff).map(\.0) == [.unchanged])
    #expect(!diff.hasChanges)
    #expect(diff.precision == .exact)
  }

  @Test("AC-14: 空のテキスト同士は区間を持たない")
  func emptyTexts() {
    let diff = differ.diff(from: "", to: "")

    #expect(diff.segments.isEmpty)
    #expect(!diff.hasChanges)
  }

  @Test("AC-14: 全体の挿入・全体の削除")
  func wholeInsertionAndDeletion() {
    #expect(pairs(differ.diff(from: "", to: "追加")).map(\.0) == [.inserted])
    #expect(pairs(differ.diff(from: "削除", to: "")).map(\.0) == [.deleted])
  }

  @Test("AC-14: 日本語の置き換えを削除・挿入の順に返す")
  func japaneseReplacement() {
    let diff = differ.diff(from: "会議は3時からです", to: "会議は4時からです")

    #expect(pairs(diff).map(\.0) == [.unchanged, .deleted, .inserted, .unchanged])
    #expect(pairs(diff).map(\.1) == ["会議は", "3", "4", "時からです"])
  }

  @Test("AC-14: 中間への挿入と削除を区別する")
  func insertionAndDeletionInMiddle() {
    let inserted = differ.diff(from: "明日は休みです", to: "明日は午後から休みです")
    #expect(pairs(inserted).map(\.0) == [.unchanged, .inserted, .unchanged])
    #expect(pairs(inserted).map(\.1) == ["明日は", "午後から", "休みです"])

    let deleted = differ.diff(from: "とても大事な連絡です", to: "大事な連絡です")
    #expect(pairs(deleted).map(\.0) == [.deleted, .unchanged])
    #expect(pairs(deleted).map(\.1) == ["とても", "大事な連絡です"])
  }

  @Test(
    "AC-14: 書記素クラスターを分割しない",
    arguments: [
      ("家族👨‍👩‍👧で行く", "家族👨‍👩‍👦で行く"),
      ("🇯🇵と🇺🇸", "🇯🇵と🇬🇧"),
      ("cafe\u{301}です", "cafeです"),
      ("👍🏻いいね", "👍🏿いいね"),
    ]
  )
  func keepsGraphemeClusters(_ original: String, _ edited: String) {
    let diff = differ.diff(from: original, to: edited)

    #expect(diff.hasChanges)
    // 変更のあった区間はどちらも書記素1つ分で、Unicode スカラーの途中で切れていない
    let changed = diff.segments.filter { $0.kind != .unchanged }
    #expect(changed.map(\.text.count) == [1, 1] || changed.map(\.text.count) == [1])
    #expect(diff.originalText == original)
    #expect(diff.editedText == edited)
  }

  @Test("AC-14: 正準等価な文字は変更なしとみなす")
  func canonicalEquivalenceIsUnchanged() {
    // 合成済みの「é」と、「e」＋結合アクセント
    let diff = differ.diff(from: "caf\u{E9}", to: "cafe\u{301}")

    #expect(!diff.hasChanges)
  }

  @Test(
    "AC-14: 組み立て直すと元と編集後に一致し、差分は最短になる",
    arguments: 0..<40
  )
  func reconstructsAndIsMinimal(_ seed: Int) {
    var generator = SeededGenerator(state: UInt64(seed) &+ 1)
    let alphabet: [Character] = ["あ", "い", "う", "a", "b", "😀", "、"]
    func randomText() -> String {
      let length = Int.random(in: 0...30, using: &generator)
      return String((0..<length).map { _ in alphabet.randomElement(using: &generator)! })
    }
    let original = randomText()
    let edited = randomText()

    let diff = differ.diff(from: original, to: edited)

    #expect(diff.precision == .exact)
    #expect(diff.originalText == original)
    #expect(diff.editedText == edited)
    let editDistance = diff.segments.filter { $0.kind != .unchanged }.map(\.text.count)
      .reduce(0, +)
    let lcs = Self.lcsLength(Array(original), Array(edited))
    #expect(editDistance == original.count + edited.count - 2 * lcs)
  }

  @Test("AC-14: 同じ種類の区間は隣り合わず、変更のまとまりでは削除が先に来る", arguments: 0..<20)
  func segmentsAreNormalized(_ seed: Int) {
    var generator = SeededGenerator(state: UInt64(seed) &+ 100)
    let alphabet: [Character] = ["x", "y", "z"]
    func randomText() -> String {
      String((0..<20).map { _ in alphabet.randomElement(using: &generator)! })
    }

    let diff = differ.diff(from: randomText(), to: randomText())

    for (previous, next) in zip(diff.segments, diff.segments.dropFirst()) {
      #expect(previous.kind != next.kind)
      #expect(!(previous.kind == .inserted && next.kind == .deleted))
    }
    #expect(diff.segments.allSatisfy { !$0.text.isEmpty })
  }

  @Test("AC-14: 文字数の上限を超えると共通の先頭・末尾以外をまとめた近似の差分を返す")
  func approximatesWhenTooLong() {
    let differ = TextDiffer(maxCharacterCount: 4)

    let diff = differ.diff(from: "前abc後", to: "前xyz後")

    #expect(diff.precision == .approximate)
    #expect(pairs(diff).map(\.0) == [.unchanged, .deleted, .inserted, .unchanged])
    #expect(pairs(diff).map(\.1) == ["前", "abc", "xyz", "後"])
  }

  @Test("AC-14: 編集距離の上限を超えると近似の差分を返す")
  func approximatesWhenEditDistanceExceedsLimit() {
    let differ = TextDiffer(maxEditDistance: 2)

    let within = differ.diff(from: "a1b", to: "a2b")
    #expect(within.precision == .exact)

    let beyond = differ.diff(from: "a1b2c", to: "a3b4c")
    #expect(beyond.precision == .approximate)
    #expect(pairs(beyond).map(\.1) == ["a", "1b2", "3b4", "c"])
    #expect(beyond.originalText == "a1b2c")
    #expect(beyond.editedText == "a3b4c")
  }

  @Test("AC-14: 共通の先頭・末尾は上限の文字数に数えない")
  func commonAffixesDoNotCountTowardLimit() {
    let differ = TextDiffer(maxCharacterCount: 2, maxEditDistance: 2)
    let longCommon = String(repeating: "あ", count: 50_000)

    let diff = differ.diff(from: longCommon + "1" + longCommon, to: longCommon + "2" + longCommon)

    #expect(diff.precision == .exact)
    #expect(pairs(diff).map(\.0) == [.unchanged, .deleted, .inserted, .unchanged])
  }

  @Test("AC-14: 片側が空になる差分は上限によらず正確")
  func oneSidedChangeIsExactRegardlessOfLimit() {
    let differ = TextDiffer(maxCharacterCount: 0, maxEditDistance: 0)

    let diff = differ.diff(from: "前置き本文", to: "本文")

    #expect(diff.precision == .exact)
    #expect(pairs(diff).map(\.1) == ["前置き", "本文"])
  }

  @Test("AC-14: 負の上限は0として扱う")
  func clampsNegativeLimits() {
    let differ = TextDiffer(maxCharacterCount: -1, maxEditDistance: -5)

    #expect(differ.maxCharacterCount == 0)
    #expect(differ.maxEditDistance == 0)
    #expect(differ.diff(from: "a", to: "b").precision == .approximate)
  }

  @Test("AC-14: 文字列表現とリフレクションに本文を出さない")
  func redactsText() {
    let diff = differ.diff(from: "秘密の本文", to: "公開の本文")
    let segment = diff.segments[0]

    for rendered in [
      String(describing: diff), String(reflecting: diff), String(describing: segment),
      String(reflecting: segment),
    ] {
      #expect(!rendered.contains("秘密"))
      #expect(!rendered.contains("公開"))
      #expect(!rendered.contains("本文"))
    }
    #expect(Mirror(reflecting: segment).children.map(\.label) == ["kind", "length"])
  }
}
