import Foundation
import Testing
import UtterCore

/// 読み戻しの判定・入力対象の識別・表示の秘匿（INS-01, INS-05, AC-09）。
struct InsertionReadBackTests {
  private static func snapshot(_ value: String?, _ location: Int?, _ length: Int = 0)
    -> FieldSnapshot
  {
    FieldSnapshot(
      value: value,
      selection: location.map { FieldSnapshot.Selection(location: $0, length: length) })
  }

  // MARK: ReadBackEvaluator

  @Test("INS-05: カーソル位置へ入った値と完全一致すれば一致とする")
  func matchesAtCursor() {
    let before = Self.snapshot("前後", 1)

    #expect(ReadBackEvaluator.evaluate(before: before, after: "前中後", text: "中") == .matches)
    #expect(ReadBackEvaluator.evaluate(before: before, after: "前後中", text: "中") == .differs)
  }

  @Test("INS-05: 選択範囲を置き換えた値と比べる")
  func replacesSelection() {
    let before = Self.snapshot("hello world", 6, 5)

    #expect(
      ReadBackEvaluator.evaluate(before: before, after: "hello utter", text: "utter") == .matches)
  }

  @Test("INS-05: 値が変わらなければ変化なし、一部だけ変われば期待どおりでないとする")
  func unchangedAndDiffers() {
    let before = Self.snapshot("abc", 3)

    #expect(ReadBackEvaluator.evaluate(before: before, after: "abc", text: "xyz") == .unchanged)
    #expect(ReadBackEvaluator.evaluate(before: before, after: "abcx", text: "xyz") == .differs)
  }

  @Test("INS-05: 挿入前か後の値を読めなければ読み戻せないとする")
  func unavailable() {
    #expect(
      ReadBackEvaluator.evaluate(before: Self.snapshot(nil, nil), after: "x", text: "x")
        == .unavailable)
    #expect(
      ReadBackEvaluator.evaluate(before: Self.snapshot("a", 1), after: nil, text: "x")
        == .unavailable)
  }

  @Test("INS-05: 選択範囲が取れなければ、長さと出現回数がちょうど1つ分増えたかで判定する")
  func withoutSelection() {
    let before = Self.snapshot("#a #a", nil)

    #expect(ReadBackEvaluator.evaluate(before: before, after: "#a #a#a", text: "#a") == .matches)
    #expect(
      ReadBackEvaluator.evaluate(before: before, after: "#a #a#a#a", text: "#a") == .differs)
    #expect(ReadBackEvaluator.evaluate(before: before, after: "#a #a", text: "#a") == .unchanged)
  }

  @Test("INS-05: 選択範囲は UTF-16 単位で扱い、値と合わない範囲では期待値を作らない")
  func utf16Selection() {
    // 絵文字はサロゲートペア（UTF-16 で2単位）
    #expect(Self.snapshot("😀", 2).expectedValue(inserting: "x") == "😀x")
    #expect(Self.snapshot("😀", 1).expectedValue(inserting: "x") == nil)
    #expect(Self.snapshot("ab", 3).expectedValue(inserting: "x") == nil)
    #expect(Self.snapshot("ab", 1, 5).expectedValue(inserting: "x") == nil)
    #expect(Self.snapshot("ab", -1).expectedValue(inserting: "x") == nil)
    #expect(Self.snapshot("ab", 1, Int.max).expectedValue(inserting: "x") == nil)
  }

  // MARK: TargetIdentityRegistry

  @Test("INS-01: 録音開始時と同じ要素には同じ識別子、別の要素には別の識別子を返す")
  func identity() {
    var counter = 0
    var registry = TargetIdentityRegistry<String>(
      isSame: ==,
      makeID: {
        counter += 1
        return InsertionTargetID(rawValue: "id-\(counter)")
      })

    let recorded = registry.record("field-A")

    #expect(registry.identify("field-A") == recorded)
    let other = registry.identify("field-B")
    #expect(other != recorded)
    #expect(registry.identify("field-B") == other)
    #expect(registry.element(for: recorded) == "field-A")
    #expect(registry.element(for: other) == "field-B")
  }

  @Test("INS-01: 記録し直すと前の要素を忘れ、記録をやめると何も対応づけない")
  func rerecordAndClear() {
    var counter = 0
    var registry = TargetIdentityRegistry<String>(
      isSame: ==,
      makeID: {
        counter += 1
        return InsertionTargetID(rawValue: "id-\(counter)")
      })
    let first = registry.record("field-A")
    let second = registry.record("field-B")

    #expect(registry.element(for: first) == nil)
    #expect(registry.identify("field-A") != first)
    #expect(registry.identify("field-B") == second)

    registry.clear()
    #expect(registry.element(for: second) == nil)
    #expect(registry.identify("field-B") != second)
  }

  // MARK: 秘匿

  @Test("iAC-10: 入力欄の値とクリップボードの中身を文字列表現に出さない")
  func redactsContents() {
    let field = FieldSnapshot(
      value: "秘密の本文", selection: FieldSnapshot.Selection(location: 0, length: 0))
    let clipboard = PasteboardSnapshot(
      items: [[PasteboardSnapshot.Entry(type: "public.utf8-plain-text", data: Data("秘密".utf8))]],
      unreadableTypeCount: 0)

    for output in [
      String(describing: field), String(reflecting: field),
      String(describing: clipboard), String(reflecting: clipboard),
    ] {
      #expect(!output.contains("秘密"))
    }
  }

  @Test(
    "AC-09: プレビューの理由の文言は、どの理由でも空でなく、文字列の中身を含まない",
    arguments: [
      InsertionPreviewCause.plan(.targetUnknown), .plan(.targetMissing), .plan(.targetChanged),
      .plan(.allRoutesFailed), .plan(.noAvailableRoute), .plan(.multilineInTerminal),
      .sensitiveInput([.secureField]), .accessibilityNotTrusted, .insertionInProgress, .cancelled,
      .recoveredAfterRestart,
    ])
  func previewMessages(_ cause: InsertionPreviewCause) {
    #expect(!InsertionPreviewMessage.text(for: cause).isEmpty)
  }
}
