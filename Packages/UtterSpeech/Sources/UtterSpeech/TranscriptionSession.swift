import AVFoundation
import Speech

/// 1回の認識で使う解析器（4章）。`SpeechAnalyzerRecognizer` の進め方（`TranscriptionRun`）を、OS のモデルなしで
/// テストできるよう、SpeechAnalyzer の呼び出しをこの protocol に切り出す。本番は `SpeechAnalyzerSession`。
protocol TranscriptionSession: Sendable {
  associatedtype Results: AsyncSequence<TranscriptionSegment, any Error>

  /// 解析器が受け付ける音声形式
  var audioFormat: AVAudioFormat { get }
  /// モデルをロードする（時間がかかりうる）
  func prepare() async throws
  /// 音声の入力を渡して解析を始める
  func start(_ inputs: AsyncStream<AnalyzerInput>) async throws
  /// 認識結果。1回の認識で1回だけ読む
  func results() -> Results
  /// 入力の終わりまでを確定させて終える
  func finalize() async throws
  /// 直ちに止めて資源を解放する。何回呼んでもよい
  func cancel() async
}

/// SpeechAnalyzer / SpeechTranscriber による `TranscriptionSession`。
struct SpeechAnalyzerSession: TranscriptionSession {
  let analyzer: SpeechAnalyzer
  let transcriber: SpeechTranscriber
  let audioFormat: AVAudioFormat

  /// ロケールを解決し、モデルの取得状態と音声形式を確かめる。モデルは取得しない（PERM-03）。
  static func make(locale: Locale) async -> Result<Self, SpeechRecognitionError> {
    guard SpeechTranscriber.isAvailable,
      let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
    else { return .failure(.modelUnavailable) }
    let transcriber = makeTranscriber(locale: supported)
    guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
      return .failure(.modelUnavailable)
    }
    guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
    else { return .failure(.unsupportedAudioFormat) }
    // 優先度は Probe と同じく明示する。モデル保持は Probe の既定（whileInUse）に合わせ、Phase 0 の計測結果で見直す
    let analyzer = SpeechAnalyzer(
      modules: [transcriber],
      options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .whileInUse))
    return .success(Self(analyzer: analyzer, transcriber: transcriber, audioFormat: format))
  }

  /// 暫定・確定結果を流す設定（`progressiveTranscription`）に、確定した範囲の後に残る暫定結果を切り出すための
  /// 音声の時刻の属性を足す。モデルの状態の確認と取得（`SpeechAnalyzerAssets`）でも同じ設定を使う。
  static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
    let preset = SpeechTranscriber.Preset.progressiveTranscription
    return SpeechTranscriber(
      locale: locale, transcriptionOptions: preset.transcriptionOptions,
      reportingOptions: preset.reportingOptions,
      attributeOptions: preset.attributeOptions.union([.audioTimeRange]))
  }

  func prepare() async throws {
    try await analyzer.prepareToAnalyze(in: audioFormat)
  }

  func start(_ inputs: AsyncStream<AnalyzerInput>) async throws {
    try await analyzer.start(inputSequence: inputs)
  }

  func results() -> some AsyncSequence<TranscriptionSegment, any Error> {
    transcriber.results.map { TranscriptionSegment($0) }
  }

  func finalize() async throws {
    try await analyzer.finalizeAndFinishThroughEndOfInput()
  }

  func cancel() async {
    await analyzer.cancelAndFinishNow()
  }
}

extension TranscriptionSegment {
  /// SpeechTranscriber の結果から作る。時刻は音声の先頭からの秒
  init(_ result: SpeechTranscriber.Result) {
    let text = result.text
    let runs = text.runs.map { run in
      Run(text: String(text[run.range].characters), start: run.audioTimeRange?.start.seconds)
    }
    self.init(isFinal: result.isFinal, runs: runs, end: result.range.end.seconds)
  }
}
