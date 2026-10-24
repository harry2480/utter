import UtterCore
import UtterSpeech

/// iOS の STT エンジンが未設定のときに使う音声認識（4章）。認識せず、録音の終了後に失敗を返す。
///
/// iOS の STT エンジンは Phase i0（#54）の判定待ちのため、既定ではこれを差し込む。
/// 録音は止めないよう、音声のストリームが終わるまで読み（中身は使わず、保持もしない）、
/// 終わったら `failed(.modelUnavailable)` を1回だけ流す。判定後は SpeechAnalyzer などのアダプターに置き換える。
public struct UnconfiguredSpeechRecognizer: SpeechRecognizer {
  public init() {}

  public func recognize(
    _ audio: AsyncStream<AudioChunk>, session: SessionID
  ) -> AsyncStream<RecognitionEvent> {
    let (stream, continuation) = AsyncStream.makeStream(of: RecognitionEvent.self)
    let task = Task {
      defer { continuation.finish() }
      for await _ in audio {
        if Task.isCancelled { return }
      }
      if !Task.isCancelled {
        continuation.yield(
          RecognitionEvent(sessionID: session, sequence: 0, kind: .failed(.modelUnavailable)))
      }
    }
    continuation.onTermination = { _ in task.cancel() }
    return stream
  }
}
