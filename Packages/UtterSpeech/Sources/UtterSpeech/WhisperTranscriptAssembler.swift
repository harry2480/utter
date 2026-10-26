/// WhisperKit の推論結果を、`partial` / `confirmed` / `completed` に変換する（4章, 2.2節）。
///
/// WhisperKit はまとまった音声を推論するエンジンのため、次の方法で逐次の結果を作る
/// （WhisperKit の `AudioStreamTranscriber` と同じ考え方）。
/// 1. 届いた音声のうち、まだ確定していない部分（未確定の音声）を持つ
/// 2. 新しい音声が `transcriptionInterval` だけたまるたびに、未確定の音声全体を推論し直す
/// 3. 推論結果の区間のうち、末尾の `requiredSegmentsForConfirmation` 個より前を確定にし（`confirmed`）、
///    確定した区間の終わりまでの音声を捨てる。残りの区間は暫定（`partial`）にする。
///    確定する区間の終わりが未確定の音声の先頭・終わりの外にあるとき（時刻がずれた結果）は確定しない。
///    未確定の音声が `maximumPendingDuration` を超えたら、推論の量が増え続けないよう減らす
/// 4. 音声が終わったら、未確定の音声を最後に推論し、全体を `completed` にする
///
/// テキストは区間のテキストを区切りを足さずに連結する（Whisper の区間は必要な空白を先頭に含む）。
/// 全体の先頭の空白と、`completed` の末尾の空白は取り除く。空白だけの区間は無視する。
///
/// 推論はしない。推論は呼び出し側（`WhisperKitRecognizer`）が `SegmentTranscriber` で行う。
public struct WhisperTranscriptAssembler: Sendable {
  /// 未確定の音声の上限（仮置き。Whisper が一度に扱う30秒に合わせた）。超えたら、末尾の1区間を残して確定するか、
  /// 区間がなければ（無音）`retainedSilenceDuration` を残して捨てる。#49 の実測で見直す
  public static let maximumPendingDuration: Duration = .seconds(30)
  /// 無音で未確定の音声を減らすときに残す長さ（仮置き）
  public static let retainedSilenceDuration: Duration = .seconds(5)

  public let configuration: WhisperKitRecognizerConfiguration
  /// これまでに確定したテキストを連結したもの
  public private(set) var confirmedText = ""
  /// 未確定の音声。次の推論に渡す
  public private(set) var pendingSamples: [Float] = []
  /// 最後に推論してから届いたサンプル数
  private var samplesSinceLastTranscription = 0
  /// 受け手が表示している暫定テキスト（`confirmed` の後は空）
  private var displayedPartial = ""

  public init(configuration: WhisperKitRecognizerConfiguration) {
    self.configuration = configuration
  }

  /// 未確定の音声があるか
  public var hasPendingAudio: Bool {
    !pendingSamples.isEmpty
  }

  /// 音声を加える。サンプリング周波数が WhisperKit と違えば `.unsupportedAudioFormat` を投げ、音声を加えない。
  /// - Returns: 推論し直す時期か（前回の推論から `transcriptionInterval` 以上の音声が届いた）
  public mutating func append(_ chunk: AudioChunk) throws(SpeechRecognitionError) -> Bool {
    guard chunk.sampleRate == WhisperKitRecognizerConfiguration.sampleRate else {
      throw .unsupportedAudioFormat
    }
    pendingSamples += chunk.samples
    samplesSinceLastTranscription += chunk.samples.count
    return samplesSinceLastTranscription >= configuration.transcriptionIntervalSampleCount
  }

  /// 録音の途中の推論結果を反映する。`segments` は、いまの `pendingSamples` を推論した結果とする。
  /// - Returns: 受け手に流すイベント（`confirmed` → `partial` の順。変化がなければ空）
  public mutating func applyIntermediate(_ segments: [TranscribedSegment]) -> [RecognitionEvent
    .Kind]
  {
    samplesSinceLastTranscription = 0
    var events: [RecognitionEvent.Kind] = []
    var remaining = Self.nonBlank(segments)
    confirm(
      count: remaining.count - configuration.requiredSegmentsForConfirmation, of: &remaining,
      events: &events)
    // 未確定の音声が長くなりすぎたら、推論し直す量が増え続けないよう減らす
    if pendingSamples.count > Self.sampleCount(of: Self.maximumPendingDuration) {
      if remaining.isEmpty {
        // 区間がない（無音）なら、末尾だけを残して捨てる。話し始めを切らないよう末尾は残す
        let keep = Self.sampleCount(of: Self.retainedSilenceDuration)
        pendingSamples.removeFirst(pendingSamples.count - keep)
      } else {
        confirm(count: remaining.count - 1, of: &remaining, events: &events)
      }
    }
    let partial = normalized(remaining.map(\.text).joined())
    if partial != displayedPartial {
      events.append(.partial(partial))
      displayedPartial = partial
    }
    return events
  }

  /// `segments` の先頭 `count` 個を確定にし、その終わりまでの音声を捨てる
  private mutating func confirm(
    count: Int, of segments: inout [TranscribedSegment], events: inout [RecognitionEvent.Kind]
  ) {
    guard count > 0, count <= segments.count else { return }
    let confirming = segments.prefix(count)
    guard let lastConfirming = confirming.last else { return }
    let endSample = sampleOffset(of: lastConfirming.end)
    // 区間の終わりが音声の先頭から進まないなら、確定すると同じ音声を2回認識しうるため確定しない。
    // 未確定の音声の終わりに達するなら、残る区間に対応する音声がなくなり、そのテキストを失うため確定しない
    // （次の推論か、音声の終わりの推論で扱う）
    guard endSample > 0, endSample < pendingSamples.count else { return }
    let text = normalized(confirming.map(\.text).joined())
    if !text.isEmpty {
      confirmedText += text
      events.append(.confirmed(text))
      displayedPartial = ""
    }
    pendingSamples.removeFirst(endSample)
    segments.removeFirst(count)
  }

  /// 最後の推論結果を反映し、全体の確定テキストを返す。`segments` は、いまの `pendingSamples` を推論した結果
  /// （未確定の音声がなければ空）とする
  public mutating func complete(_ segments: [TranscribedSegment]) -> RecognitionEvent.Kind {
    let tail = normalized(Self.nonBlank(segments).map(\.text).joined())
    confirmedText += tail
    confirmedText = String(confirmedText.reversed().drop(while: \.isWhitespace).reversed())
    pendingSamples = []
    samplesSinceLastTranscription = 0
    displayedPartial = ""
    return .completed(confirmedText)
  }

  /// まだ何も確定していなければ先頭の空白を取り除く
  private func normalized(_ text: String) -> String {
    confirmedText.isEmpty ? String(text.drop(while: \.isWhitespace)) : text
  }

  /// 区間の終わりを `pendingSamples` の位置にする（0〜`pendingSamples.count`。外は端にそろえる）
  private func sampleOffset(of end: Duration) -> Int {
    let (seconds, attoseconds) = end.components
    let position =
      (Double(seconds) + Double(attoseconds) / 1e18)
      * Double(WhisperKitRecognizerConfiguration.sampleRate)
    guard position.isFinite, position > 0 else {
      return 0
    }
    return min(pendingSamples.count, Int(min(position.rounded(), Double(Int.max / 2))))
  }

  private static func sampleCount(of duration: Duration) -> Int {
    let (seconds, attoseconds) = duration.components
    return Int(seconds) * WhisperKitRecognizerConfiguration.sampleRate
      + Int(attoseconds / 1_000_000_000_000) * WhisperKitRecognizerConfiguration.sampleRate
      / 1_000_000
  }

  private static func nonBlank(_ segments: [TranscribedSegment]) -> [TranscribedSegment] {
    segments.filter { !$0.text.allSatisfy(\.isWhitespace) }
  }
}

// 認識テキストと音声をログに出さないよう、文字列表現とリフレクションには文字数とサンプル数だけを出す。
extension WhisperTranscriptAssembler: CustomStringConvertible, CustomReflectable {
  public var description: String {
    "WhisperTranscriptAssembler(confirmedLength: \(confirmedText.count), "
      + "pendingSampleCount: \(pendingSamples.count))"
  }

  public var customMirror: Mirror {
    Mirror(self, children: ["description": description])
  }
}
