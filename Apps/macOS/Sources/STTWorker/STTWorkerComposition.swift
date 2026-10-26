import UtterSpeech

/// STT Worker を使う音声認識の組み立て（4章, 7章, AC-10）。
///
/// `AppComposition` が組み立てて `SessionCoordinator` に渡す。
enum STTWorkerComposition {
  /// 一時音声からの再処理（`RecordedAudio` を同じ `SessionID` で認識し直す, AC-10）は、`SessionCoordinator` が失敗を受け取った後に
  /// `STTWorkerRecognitionRecovery`（`termination(of:)`）で異常終了かを確かめて行う。`onTermination` は失敗を流した後に届くため、
  /// セッションの進行には使わない
  /// - Parameters:
  ///   - engine: 使うエンジン。どれを既定にするかは Phase 0 の判定（11章）待ちのため、既定値を持たない。
  ///     `AppComposition.selectedEngine()` がビルド設定（`UTTER_MAC_STT_ENGINE`）から選んだものを渡す。
  ///     `nil` なら Worker を起動せず、認識は `failed(.modelUnavailable)` になる
  ///   - onTermination: 認識中に Worker が異常終了したセッション
  static func makeRecognizer(
    engine: STTEngineKind?,
    onTermination: (@Sendable (STTWorkerTermination) async -> Void)? = nil
  ) -> STTWorkerSpeechRecognizer? {
    guard let connector = XPCSTTWorkerConnector() else { return nil }
    return STTWorkerSpeechRecognizer(
      engine: engine, connector: connector, onTermination: onTermination)
  }

  /// 端末の状態の監視を `recognizer` に結線する（6章, AC-11）。
  ///
  /// 保持の方針は保存された設定の保持モードから作る（`ModelRetentionPolicy.fromSettings`）。
  /// 設定が変わったときは `AppComposition` が `DeviceResourceMonitoring.updatePolicy(_:)` で送り直す
  /// - Parameter policy: 起動時の設定から作った保持の方針
  @MainActor
  static func makeResourceMonitoring(
    for recognizer: STTWorkerSpeechRecognizer, policy: ModelRetentionPolicy
  ) -> DeviceResourceMonitoring {
    DeviceResourceMonitoring(policy: policy, receiver: recognizer)
  }
}
