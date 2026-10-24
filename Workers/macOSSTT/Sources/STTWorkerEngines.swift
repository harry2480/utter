import UtterSpeech

/// STT Worker で使えるエンジンの登録（4章 STT Worker, 11章）。
///
/// 実エンジンのアダプター（SpeechAnalyzer / WhisperKit）は、それぞれの実装がマージされたらここに登録する。
/// 登録のないエンジンを求められたら `STTWorkerService` が `failed(.modelUnavailable)` を返す。
/// どのエンジンを既定にするかは Phase 0 の判定待ちで、ここでは決めない（選ぶのはメインアプリの設定）。
enum STTWorkerEngines {
  static func loaders() -> [STTEngineKind: any SpeechModelLoader] {
    var loaders: [STTEngineKind: any SpeechModelLoader] = [:]
    #if DEBUG
      // 開発中に Worker の往復を確かめるための固定の認識結果。リリースビルドには入れない
      loaders[.stub] = StubSpeechModelLoader(steps: [.partial("stub"), .confirmed("stub")])
    #endif
    return loaders
  }
}
