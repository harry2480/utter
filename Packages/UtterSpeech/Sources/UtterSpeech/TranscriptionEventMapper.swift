/// SpeechTranscriber の1つの結果を、OS の型から切り離して表したもの（4章）。
///
/// 時刻は音声の先頭からの秒。`runs` は結果のテキストを、音声の時刻の属性（`audioTimeRange`）ごとに区切ったもの。
struct TranscriptionSegment: Hashable, Sendable {
  struct Run: Hashable, Sendable {
    let text: String
    /// この部分の音声の開始時刻。属性がなければ `nil`
    let start: Double?
  }

  /// 確定（final）か暫定（volatile）か
  let isFinal: Bool
  let runs: [Run]
  /// 結果が対象とする音声の終了時刻
  let end: Double

  var text: String { runs.map(\.text).joined() }
}

/// SpeechTranscriber の結果を `RecognitionEvent.Kind` に変換する（4章, 2.2節）。
///
/// - 暫定結果は、確定済みの範囲の後に続く部分を表すため、そのまま `partial` にする
/// - 確定結果は `confirmed` にし、確定済みテキストに連結する（日本語は区切りを足さない。結果のテキストに含まれる空白はそのまま）
/// - `RecognitionEvent` の契約では、受け手は `confirmed` で暫定結果を消す。直前の暫定結果のうち、確定した範囲より後の部分が
///   残っていれば、続けて `partial` で送り直す。範囲は音声の時刻の属性で判断し、属性がまったくなければ送り直さない
///   （次の暫定結果で表示が戻る）
/// - 入力の終わりの `completed` には `completedText`（確定テキストに、確定結果がカバーしていない末尾の暫定部分を足したもの）を
///   使う。暫定結果が確定として出し直される保証はなく、確定で変わらなかった範囲には新しい確定結果が出ないことがあるため
///   （SpeechModuleResult.isFinal / resultsFinalizationTime）、発話の終わりを落とさないよう安全側に倒す
///
/// 値型で、1回の認識の中だけで使う。
struct TranscriptionEventMapper: Hashable, Sendable {
  /// これまでの確定結果を連結したもの。`confirmed` の値を順につないだものと同じ
  private(set) var confirmedText = ""
  /// 最後に流した暫定結果（確定結果で送り直した残りを含む）
  private var lastVolatile: TranscriptionSegment?
  /// これまでの確定結果が対象とした音声の終了時刻のうち最も遅いもの。確定結果がなければ `nil`
  private var confirmedEnd: Double?

  /// 確定した範囲の終わりと、暫定結果の部分の開始を比べるときの許容誤差（秒）。時刻の丸めで部分を取りこぼさないため
  static let timeTolerance = 0.001

  init() {}

  mutating func map(_ segment: TranscriptionSegment) -> [RecognitionEvent.Kind] {
    guard segment.isFinal else {
      lastVolatile = segment
      return [.partial(segment.text)]
    }
    let text = segment.text
    confirmedText += text
    confirmedEnd = max(confirmedEnd ?? segment.end, segment.end)
    var kinds: [RecognitionEvent.Kind] = [.confirmed(text)]
    // 時刻は前から順に並ぶため、確定した範囲の終わり以降で時刻のある最初の部分から後ろを残す
    // （途中にある時刻のない部分、たとえば単語の間の空白も残す）
    let firstRemaining = lastVolatile?.runs.firstIndex { run in
      run.start.map { $0 >= segment.end - Self.timeTolerance } ?? false
    }
    if let previous = lastVolatile, let firstRemaining {
      let rest = TranscriptionSegment(
        isFinal: false, runs: Array(previous.runs[firstRemaining...]), end: previous.end)
      lastVolatile = rest
      kinds.append(.partial(rest.text))
    } else {
      lastVolatile = nil
    }
    return kinds
  }

  /// 入力の終わりで認識を終えるときの全体のテキスト（`completed` の値）。
  ///
  /// 確定テキストの後に、最後の暫定結果のうち確定結果がカバーしていない部分を足す。暫定結果が後から確定として
  /// 出し直された場合は、確定で暫定結果が消える（または確定した範囲より後の残りだけになる）ため二重にならない。
  /// 空白だけの末尾は足さない。
  var completedText: String { confirmedText + unfinalizedTail }

  /// 最後の暫定結果のうち、確定結果がカバーしていない部分のテキスト。
  ///
  /// 確定結果があれば、結果の範囲の終わりが確定した範囲の終わり以前の暫定結果は確定に含まれるとみなす。
  /// 時刻の属性があれば確定した範囲の終わり以降で時刻のある最初の部分から後ろを使い（`map(_:)` の送り直しと同じ）、
  /// 属性がまったくなければ、最後の確定の後に届いた暫定結果のテキスト全体を使う
  /// （確定の前に届いた属性のない暫定結果は、確定の時点で捨てているため含まれない）。
  private var unfinalizedTail: String {
    guard let volatile = lastVolatile else { return "" }
    var runs = volatile.runs[...]
    if let confirmedEnd {
      guard volatile.end > confirmedEnd + Self.timeTolerance else { return "" }
      if volatile.runs.contains(where: { $0.start != nil }) {
        let first = volatile.runs.firstIndex { run in
          run.start.map { $0 >= confirmedEnd - Self.timeTolerance } ?? false
        }
        guard let first else { return "" }
        runs = volatile.runs[first...]
      }
    }
    let text = runs.map(\.text).joined()
    return text.allSatisfy(\.isWhitespace) ? "" : text
  }
}

// 認識テキストをログに出さないよう、文字列表現とリフレクションには文字数だけを出す。
extension TranscriptionSegment: CustomStringConvertible, CustomReflectable {
  var description: String {
    "TranscriptionSegment(isFinal: \(isFinal), runCount: \(runs.count), length: \(text.count), end: \(end))"
  }

  var customMirror: Mirror {
    Mirror(self, children: ["description": description])
  }
}

extension TranscriptionEventMapper: CustomStringConvertible, CustomReflectable {
  var description: String {
    "TranscriptionEventMapper(confirmedLength: \(confirmedText.count), "
      + "hasVolatile: \(lastVolatile != nil))"
  }

  var customMirror: Mirror {
    Mirror(self, children: ["description": description])
  }
}
