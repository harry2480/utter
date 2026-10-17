/// 変更前と変更後のテキストの差分（AC-14 の差分プレビュー用）。
///
/// 区間は先頭から順に並び、同じ種類の区間は隣り合わない。変更のまとまりの中では削除を挿入より先に置く。
/// `unchanged` と `inserted` をつなぐと変更後のテキストに、`unchanged` と `deleted` をつなぐと
/// 変更前のテキストに（Unicode の正準等価の範囲で）一致する。`unchanged` の文字は変更後の側から取る。
public struct TextDiff: Hashable, Sendable {
  /// 差分の精度。
  public enum Precision: Hashable, Sendable {
    /// 最短の編集（Character 単位）で求めた差分
    case exact
    /// 入力が上限を超えたため、共通の先頭・末尾以外をまとめて削除・挿入として扱った差分
    case approximate
  }

  public let segments: [TextDiffSegment]
  public let precision: Precision

  /// 区間の並びの約束を保つため、`TextDiffer` だけが作る。
  init(segments: [TextDiffSegment], precision: Precision) {
    self.segments = segments
    self.precision = precision
  }

  /// 挿入または削除を含むか。
  public var hasChanges: Bool {
    segments.contains { $0.kind != .unchanged }
  }

  /// 変更前のテキストを組み立て直す。
  public var originalText: String {
    segments.filter { $0.kind != .inserted }.map(\.text).joined()
  }

  /// 変更後のテキストを組み立て直す。
  public var editedText: String {
    segments.filter { $0.kind != .deleted }.map(\.text).joined()
  }
}

/// 差分の1区間。
public struct TextDiffSegment: Hashable, Sendable {
  public enum Kind: Hashable, Sendable, CaseIterable {
    case unchanged
    case inserted
    case deleted
  }

  public let kind: Kind
  public let text: String

  public init(kind: Kind, text: String) {
    self.kind = kind
    self.text = text
  }
}

// 選択テキストや編集案をログに出さないよう、文字列表現とリフレクションには種類と文字数だけを出す。
extension TextDiff: CustomStringConvertible, CustomReflectable {
  public var description: String {
    "TextDiff(precision: \(precision), segments: \(segments.count))"
  }

  public var customMirror: Mirror {
    Mirror(self, children: ["precision": precision, "segments": segments.count])
  }
}

extension TextDiffSegment: CustomStringConvertible, CustomReflectable {
  public var description: String {
    "TextDiffSegment(kind: \(kind), length: \(text.count))"
  }

  public var customMirror: Mirror {
    Mirror(self, children: ["kind": kind, "length": text.count])
  }
}

/// 2つのテキストの差分を Character（書記素クラスター）単位で求める（AC-14）。
///
/// 共通の先頭・末尾を除いた残りに Myers の差分アルゴリズムを使う。計算量は残りの文字数を N、
/// 編集距離を D として時間 O(N·D)、追加の記憶域 O(D²)。上限を超える入力では最短の差分を求めず、
/// 残りをまとめて削除・挿入とした `approximate` の差分を返す。
public struct TextDiffer: Hashable, Sendable {
  /// 共通の先頭・末尾を除いた残りの文字数（変更前と変更後の合計）の既定の上限
  public static let defaultMaxCharacterCount = 10_000
  /// 編集距離（削除と挿入の文字数の合計）の既定の上限
  public static let defaultMaxEditDistance = 1_000

  public let maxCharacterCount: Int
  public let maxEditDistance: Int

  /// 負の上限は 0 として扱う。
  public init(
    maxCharacterCount: Int = defaultMaxCharacterCount,
    maxEditDistance: Int = defaultMaxEditDistance
  ) {
    self.maxCharacterCount = max(0, maxCharacterCount)
    self.maxEditDistance = max(0, maxEditDistance)
  }

  public func diff(from original: String, to edited: String) -> TextDiff {
    let old = Array(original)
    let new = Array(edited)

    var prefix = 0
    while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] {
      prefix += 1
    }
    var suffix = 0
    while suffix < old.count - prefix, suffix < new.count - prefix,
      old[old.count - 1 - suffix] == new[new.count - 1 - suffix]
    {
      suffix += 1
    }

    let oldMiddle = old[prefix..<(old.count - suffix)]
    let newMiddle = new[prefix..<(new.count - suffix)]

    var builder = SegmentBuilder()
    builder.append(.unchanged, new[..<prefix])

    var precision = TextDiff.Precision.exact
    if oldMiddle.isEmpty || newMiddle.isEmpty {
      builder.append(.deleted, oldMiddle)
      builder.append(.inserted, newMiddle)
    } else if oldMiddle.count + newMiddle.count <= maxCharacterCount,
      let operations = Self.shortestEdit(Array(oldMiddle), Array(newMiddle), limit: maxEditDistance)
    {
      for operation in operations {
        builder.append(operation.kind, CollectionOfOne(operation.character))
      }
    } else {
      precision = .approximate
      builder.append(.deleted, oldMiddle)
      builder.append(.inserted, newMiddle)
    }

    builder.append(.unchanged, new[(new.count - suffix)...])
    return TextDiff(segments: builder.finish(), precision: precision)
  }

  private struct Operation {
    let kind: TextDiffSegment.Kind
    let character: Character
  }

  /// Myers の差分アルゴリズムで最短の編集を求める。編集距離が `limit` を超える場合は nil。
  private static func shortestEdit(_ old: [Character], _ new: [Character], limit: Int)
    -> [Operation]?
  {
    let n = old.count
    let m = new.count
    let maxDistance = min(n + m, limit)
    let offset = maxDistance + 1
    // v[offset + k] は対角線 k（x - y）上で到達した最も遠い x
    var v = [Int](repeating: 0, count: 2 * maxDistance + 3)
    // trace[d] は d 回目の探索を終えた時点の v のうち、k が -d...d の部分
    var trace: [[Int]] = []
    var distance: Int?

    search: for d in 0...maxDistance {
      for k in stride(from: -d, through: d, by: 2) {
        var x =
          if k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1]) {
            v[offset + k + 1]
          } else {
            v[offset + k - 1] + 1
          }
        var y = x - k
        while x < n, y < m, old[x] == new[y] {
          x += 1
          y += 1
        }
        v[offset + k] = x
        if x >= n, y >= m {
          trace.append(Array(v[(offset - d)...(offset + d)]))
          distance = d
          break search
        }
      }
      trace.append(Array(v[(offset - d)...(offset + d)]))
    }
    guard let distance else { return nil }

    var operations: [Operation] = []
    operations.reserveCapacity(n + m)
    var x = n
    var y = m
    for d in stride(from: distance, to: 0, by: -1) {
      let previous = trace[d - 1]
      let k = x - y
      // previous[i] は対角線 i - (d - 1) の値
      let previousK =
        if k == -d || (k != d && previous[k - 1 + d - 1] < previous[k + 1 + d - 1]) {
          k + 1
        } else {
          k - 1
        }
      let previousX = previous[previousK + d - 1]
      let previousY = previousX - previousK
      while x > previousX, y > previousY {
        x -= 1
        y -= 1
        operations.append(Operation(kind: .unchanged, character: new[y]))
      }
      if x == previousX {
        y -= 1
        operations.append(Operation(kind: .inserted, character: new[y]))
      } else {
        x -= 1
        operations.append(Operation(kind: .deleted, character: old[x]))
      }
    }
    while x > 0, y > 0 {
      x -= 1
      y -= 1
      operations.append(Operation(kind: .unchanged, character: new[y]))
    }
    return operations.reversed()
  }
}

/// 隣り合う同じ種類の区間をまとめ、変更のまとまりの中で削除を挿入より先に並べる。
private struct SegmentBuilder {
  private var segments: [TextDiffSegment] = []
  private var unchanged = ""
  private var deleted = ""
  private var inserted = ""

  mutating func append<C: Collection<Character>>(_ kind: TextDiffSegment.Kind, _ characters: C) {
    guard !characters.isEmpty else { return }
    switch kind {
    case .unchanged:
      flushChanges()
      unchanged.append(contentsOf: characters)
    case .deleted:
      flushUnchanged()
      deleted.append(contentsOf: characters)
    case .inserted:
      flushUnchanged()
      inserted.append(contentsOf: characters)
    }
  }

  consuming func finish() -> [TextDiffSegment] {
    flushUnchanged()
    flushChanges()
    return segments
  }

  private mutating func flushUnchanged() {
    guard !unchanged.isEmpty else { return }
    segments.append(TextDiffSegment(kind: .unchanged, text: unchanged))
    unchanged = ""
  }

  private mutating func flushChanges() {
    if !deleted.isEmpty {
      segments.append(TextDiffSegment(kind: .deleted, text: deleted))
      deleted = ""
    }
    if !inserted.isEmpty {
      segments.append(TextDiffSegment(kind: .inserted, text: inserted))
      inserted = ""
    }
  }
}
