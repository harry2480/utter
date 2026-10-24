/// STT Worker で使う認識エンジンの種類（3章, 11章）。
///
/// どれを既定にするかは Phase 0 の判定（11章）で決めるため、既定値を持たない。
/// 開発用の `stub` を含むため `CaseIterable` にしない（設定画面に一覧で出さない）。
/// 未選択のまま STT Worker を起動しない（`STTWorkerSpeechRecognizer` は接続せずに失敗にする）。
public enum STTEngineKind: String, Hashable, Sendable, Codable {
  /// Apple SpeechAnalyzer / SpeechTranscriber
  case speechAnalyzer
  /// WhisperKit / Core ML
  case whisperKit
  /// 固定のイベントを流す開発用のエンジン。利用者の設定で選ばせない
  case stub
}
