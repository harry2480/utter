import UtterCore

/// 音声認識エンジンの共通インターフェース（4章）。
///
/// SpeechAnalyzer / WhisperKit の各アダプターと `StubSpeechRecognizer` がこれに準拠する。
/// OS 固有の音声型は使わず、`AudioChunk` で受け取る。
public protocol SpeechRecognizer: Sendable {
  /// `audio` を認識し、イベントを流す。
  ///
  /// - 各イベントには `session` と、0 から1ずつ増える順序番号を付ける
  /// - `completed` か `failed` を最後に1回だけ流して終える
  /// - 受け手がストリームを破棄したら、認識を止めて資源を解放する
  func recognize(
    _ audio: AsyncStream<AudioChunk>, session: SessionID
  ) -> AsyncStream<RecognitionEvent>
}
