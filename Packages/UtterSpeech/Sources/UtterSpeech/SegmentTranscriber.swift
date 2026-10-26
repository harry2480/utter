/// 音声をまとめて推論し、区間ごとのテキストを返す STT エンジンの口（4章）。
///
/// `WhisperKitRecognizer` はこれ越しに推論し、結果を `RecognitionEvent` に変換する。
/// 本番は UtterSpeechWhisperKit の `WhisperKitTranscriber`（WhisperKit）、テストは `StubSegmentTranscriber` を使う。
/// WhisperKit を UtterSpeech の依存に入れないため、エンジンの型はこの protocol の外に出さない。
public protocol SegmentTranscriber: Sendable {
  /// モデルを使える状態にする（検証とロード）。ロード済みなら何もしない。
  /// モデルの取得（通信）はしない
  func prepare() async throws(SpeechRecognitionError)

  /// `samples`（`WhisperKitRecognizerConfiguration.sampleRate` のモノラル PCM）を推論する。
  /// 区間の時刻は `samples` の先頭からの経過時間で返す。
  /// タスクがキャンセルされたら、途中で打ち切ってよい（何を投げても呼び出し側は結果を使わない）
  func transcribe(_ samples: [Float], language: String) async throws(SpeechRecognitionError)
    -> [TranscribedSegment]
}

/// 推論結果の1区間
public struct TranscribedSegment: Hashable, Sendable {
  /// 区間のテキスト
  public let text: String
  /// 区間の終わり。推論に渡した音声の先頭からの経過時間
  public let end: Duration

  public init(text: String, end: Duration) {
    self.text = text
    self.end = end
  }
}

// 認識テキストをログに出さないよう、文字列表現とリフレクションには文字数と時刻だけを出す。
extension TranscribedSegment: CustomStringConvertible, CustomReflectable {
  public var description: String {
    "TranscribedSegment(length: \(text.count), end: \(end))"
  }

  public var customMirror: Mirror {
    Mirror(self, children: ["description": description])
  }
}
