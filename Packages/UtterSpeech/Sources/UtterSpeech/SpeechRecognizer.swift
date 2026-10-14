import UtterCore

/// 音声認識エンジンの共通インターフェース（4章）。
///
/// SpeechAnalyzer / WhisperKit の各アダプターと `StubSpeechRecognizer` がこれに準拠する。
/// OS 固有の音声型は使わず、`AudioChunk` で受け取る。
public protocol SpeechRecognizer: Sendable {
  /// `audio` を認識し、イベントを流す。
  ///
  /// - `audio` の終わり（`finish()`）を録音の終了とみなす。認識が終わるまで `audio` を保持して読む
  /// - 終端イベントを流した後は `audio` を読まない。読み捨てると音声を黙って失うため、
  ///   録音側が終端イベントを受けて録音を止め、残りの音声の扱い（退避・破棄）を決める
  /// - 音声バッファの上限と、上限に達したときの通知（REC-05）は `audio` を作る側の責務とする。
  ///   実装は音声を黙って捨てない
  /// - 各イベントには `session` と、0 から1ずつ増える順序番号を付ける
  /// - `completed` か `failed` を最後に1回だけ流して終える。終端イベントを落とすバッファの設定を使わない
  /// - 受け手がストリームを破棄したら、認識を止めて資源を解放する。このときは終端イベントを流さなくてよい
  func recognize(
    _ audio: AsyncStream<AudioChunk>, session: SessionID
  ) -> AsyncStream<RecognitionEvent>
}
