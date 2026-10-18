import ApplicationServices
import Foundation
import UtterCore

/// 挿入前の入力欄の状態。値の中身はメモリ上の比較にだけ使い、記録・表示しない。
struct FieldSnapshot {
  let value: String?
  let selectedRange: CFRange?

  /// 挿入が成功したときに期待する値。選択範囲がわからない、または範囲が値と合わないときは nil
  func expectedValue(inserting text: String) -> String? {
    guard let value, let range = selectedRange else { return nil }
    let utf16 = value.utf16
    guard range.location >= 0, range.length >= 0, range.location + range.length <= utf16.count
    else { return nil }
    let start = utf16.index(utf16.startIndex, offsetBy: range.location)
    let end = utf16.index(start, offsetBy: range.length)
    guard let lower = start.samePosition(in: value), let upper = end.samePosition(in: value) else {
      return nil
    }
    return value.replacingCharacters(in: lower..<upper, with: text)
  }
}

/// 読み戻しの判定方法
enum ReadBackMethod: String {
  /// 選択範囲を置き換えた期待値との完全一致
  case range
  /// 選択範囲が取れないため、長さの増分と文字列の包含で判定（弱い判定）
  case contains
  /// 読み戻せない
  case none
}

enum ReadBackEvaluator {
  static func evaluate(before: FieldSnapshot, after: String?, text: String)
    -> (InsertionReadBack, ReadBackMethod)
  {
    guard let beforeValue = before.value, let after else { return (.unavailable, .none) }
    if let expected = before.expectedValue(inserting: text) {
      if after == expected { return (.matches, .range) }
      return (after == beforeValue ? .unchanged : .differs, .range)
    }
    if after == beforeValue { return (.unchanged, .contains) }
    let grewByText = after.utf16.count == beforeValue.utf16.count + text.utf16.count
    return (grewByText && after.contains(text) ? .matches : .differs, .contains)
  }
}

@MainActor
enum ReadBack {
  static func snapshot(_ element: AXUIElement) -> FieldSnapshot {
    FieldSnapshot(
      value: AX.string(element, AXAttribute.value),
      selectedRange: AX.selectedRange(element)
    )
  }

  /// アプリが値を反映するまで待ちながら読み戻す。一致したらすぐ返し、時間切れなら最後の判定を返す。
  static func poll(
    element: AXUIElement, before: FieldSnapshot, text: String, timeout: Double
  ) -> (InsertionReadBack, ReadBackMethod) {
    let deadline = Date().addingTimeInterval(timeout)
    var last = ReadBackEvaluator.evaluate(
      before: before, after: AX.string(element, AXAttribute.value), text: text)
    while last.0 != .matches, Date() < deadline {
      Thread.sleep(forTimeInterval: 0.05)
      last = ReadBackEvaluator.evaluate(
        before: before, after: AX.string(element, AXAttribute.value), text: text)
    }
    return last
  }
}
