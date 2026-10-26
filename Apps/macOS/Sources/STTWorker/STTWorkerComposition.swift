import UtterSpeech

/// STT Worker を使う音声認識の組み立て（4章, 7章, AC-10）。
///
/// `AppComposition` が組み立てて `SessionCoordinator` に渡す。
enum STTWorkerComposition {
  /// 使うエンジン。どれを既定にするかは Phase 0 の判定（11章）待ちのため、既定値を持たない（`nil`）。
  /// `nil` のままなら Worker を起動せず、認識は `failed(.modelUnavailable)` になる。判定後に設定値から渡す
  static let selectedEngine: STTEngineKind? = nil

  /// 一時音声からの再処理（`RecordedAudio` を同じ `SessionID` で認識し直す, AC-10）は、`SessionCoordinator` が失敗を受け取った後に
  /// `STTWorkerRecognitionRecovery`（`termination(of:)`）で異常終了かを確かめて行う。`onTermination` は失敗を流した後に届くため、
  /// セッションの進行には使わない
  /// - Parameter onTermination: 認識中に Worker が異常終了したセッション
  static func makeRecognizer(
    engine: STTEngineKind? = selectedEngine,
    onTermination: (@Sendable (STTWorkerTermination) async -> Void)? = nil
  ) -> STTWorkerSpeechRecognizer? {
    guard let connector = XPCSTTWorkerConnector() else { return nil }
    return STTWorkerSpeechRecognizer(
      engine: engine, connector: connector, onTermination: onTermination)
  }
}
