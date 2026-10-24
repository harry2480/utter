import UtterSpeech

/// STT Worker を使う音声認識の組み立て（4章, 7章, AC-10）。
///
/// 録音・セッションの結線（Phase 1）で `UtterApp` から使う。
enum STTWorkerComposition {
  /// 使うエンジン。どれを既定にするかは Phase 0 の判定（11章）待ちのため、既定値を持たない（`nil`）。
  /// `nil` のままなら Worker を起動せず、認識は `failed(.modelUnavailable)` になる。判定後に設定値から渡す
  static let selectedEngine: STTEngineKind? = nil

  /// - Parameter onTermination: 認識中に Worker が異常終了したセッション。一時音声からの再処理
  ///   （`RecordedAudio` を同じ `SessionID` で認識し直す。#59）はここから始める
  static func makeRecognizer(
    engine: STTEngineKind? = selectedEngine,
    onTermination: (@Sendable (STTWorkerTermination) async -> Void)? = nil
  ) -> STTWorkerSpeechRecognizer? {
    guard let connector = XPCSTTWorkerConnector() else { return nil }
    return STTWorkerSpeechRecognizer(
      engine: engine, connector: connector, onTermination: onTermination)
  }
}
