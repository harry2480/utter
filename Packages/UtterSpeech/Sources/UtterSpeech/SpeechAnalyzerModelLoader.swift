import Foundation

/// STT Worker に登録する SpeechAnalyzer のローダー（4章 STT Worker）。
///
/// SpeechAnalyzer のモデルは OS が管理し、認識のたびに OS が用意するため、ここではモデルを取得もロードもしない。
/// `load()` は `SpeechAnalyzerRecognizer` を返すだけで、未対応・未取得なら認識が `failed(.modelUnavailable)` で終わる
/// （取得は `SpeechAnalyzerAssets.install()` を利用者の操作で呼ぶ, PERM-03）。
///
/// どのエンジンを既定にするかは Phase 0 の判定待ち（11章）。登録しても、メインアプリの構成で
/// `STTEngineKind.speechAnalyzer` を選ばない限り使われない。
public struct SpeechAnalyzerModelLoader: SpeechModelLoader {
  /// モデルは OS のプロセスが持ち、Worker のメモリにはロードしないため軽量とする（仮置き。Phase 0 の実測で見直す）
  public let weight: ModelWeight = .light
  public let locale: Locale

  public init(locale: Locale = SpeechAnalyzerRecognizer.defaultLocale) {
    self.locale = locale
  }

  public func load() async throws(SpeechRecognitionError) -> any SpeechRecognizer {
    SpeechAnalyzerRecognizer(locale: locale)
  }
}
