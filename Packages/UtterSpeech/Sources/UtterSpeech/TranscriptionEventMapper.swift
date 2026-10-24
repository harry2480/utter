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
///
/// 値型で、1回の認識の中だけで使う。
struct TranscriptionEventMapper: Hashable, Sendable {
  /// これまでの確定結果を連結したもの。`completed` の値に使う
  private(set) var confirmedText = ""
  /// 最後に流した暫定結果（確定結果で送り直した残りを含む）
  private var lastVolatile: TranscriptionSegment?

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
