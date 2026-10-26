import UtterSpeech

/// STT Worker で使えるエンジンの登録（4章 STT Worker, 11章）。
///
/// 実エンジンのアダプターはここに登録する。SpeechAnalyzer は登録済み、WhisperKit は実装がマージされたら登録する。
/// 登録のないエンジンを求められたら `STTWorkerService` が `failed(.modelUnavailable)` を返す。
/// どのエンジンを既定にするかは Phase 0 の判定待ちで、ここでは決めない（選ぶのはメインアプリの設定）。
enum STTWorkerEngines {
  static func loaders() -> [STTEngineKind: any SpeechModelLoader] {
    // 登録しても、メインアプリの構成で選ばない限り使われない（既定のエンジンは持たない）
    var loaders: [STTEngineKind: any SpeechModelLoader] = [
      .speechAnalyzer: SpeechAnalyzerModelLoader()
    ]
    #if DEBUG
      // 開発中に Worker の往復を確かめるための固定の認識結果。リリースビルドには入れない
      loaders[.stub] = StubSpeechModelLoader(steps: [.partial("stub"), .confirmed("stub")])
    #endif
    return loaders
  }
}
