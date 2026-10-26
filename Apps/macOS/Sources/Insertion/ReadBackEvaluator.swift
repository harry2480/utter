import Foundation
import UtterCore

/// 挿入前の入力欄の状態。値の中身はメモリ上の比較にだけ使い、記録・表示しない。
struct FieldSnapshot: Hashable, Sendable {
  /// 選択範囲（UTF-16 単位）
  struct Selection: Hashable, Sendable {
    let location: Int
    let length: Int
  }

  let value: String?
  let selection: Selection?

  /// 挿入が成功したときに期待する値。選択範囲がわからない、または範囲が値と合わないときは `nil`
  func expectedValue(inserting text: String) -> String? {
    guard let value, let selection else { return nil }
    let utf16 = value.utf16
    guard selection.location >= 0, selection.length >= 0,
      selection.location <= utf16.count - selection.length
    else { return nil }
    let start = utf16.index(utf16.startIndex, offsetBy: selection.location)
    let end = utf16.index(start, offsetBy: selection.length)
    // サロゲートペアの途中を指す範囲は使わない
    guard let lower = start.samePosition(in: value), let upper = end.samePosition(in: value) else {
      return nil
    }
    return value.replacingCharacters(in: lower..<upper, with: text)
  }
}

extension FieldSnapshot: CustomStringConvertible, CustomReflectable {
  var description: String {
    "FieldSnapshot(valueLength: \(value.map { String($0.utf16.count) } ?? "nil"))"
  }

  var customMirror: Mirror {
    Mirror(self, children: ["valueLength": value?.utf16.count as Any])
  }
}

/// 挿入後に読み戻した値を、挿入前の状態と比べる（INS-05）。
///
/// 挿入前の値と選択範囲から期待値を作り、完全一致を見る。選択範囲が取れない入力欄は、
/// 長さの増分と文字列の出現回数がちょうど1増えたかで判定する（弱い判定。AXInsertionProbe の `contains`）。
enum ReadBackEvaluator {
  static func evaluate(before: FieldSnapshot, after: String?, text: String) -> InsertionReadBack {
    guard let beforeValue = before.value, let after else { return .unavailable }
    if let expected = before.expectedValue(inserting: text) {
      if after == expected { return .matches }
      return after == beforeValue ? .unchanged : .differs
    }
    if after == beforeValue { return .unchanged }
    let grewByText = after.utf16.count == beforeValue.utf16.count + text.utf16.count
    let oneMore = occurrences(of: text, in: after) == occurrences(of: text, in: beforeValue) + 1
    return grewByText && oneMore ? .matches : .differs
  }

  /// 重ならない出現回数
  static func occurrences(of text: String, in value: String) -> Int {
    guard !text.isEmpty else { return 0 }
    return value.components(separatedBy: text).count - 1
  }
}
