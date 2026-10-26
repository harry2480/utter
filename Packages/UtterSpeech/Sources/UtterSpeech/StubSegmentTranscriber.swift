import Synchronization

/// 固定の推論結果・失敗を返すテスト用の `SegmentTranscriber`。
///
/// 推論に渡された音声のサンプル数を記録し、どの範囲を推論し直したかを確かめられる。
/// 準備・推論の前に `beforePrepare` / `beforeTranscribe` を待つため、その最中のキャンセルを再現できる。
public final class StubSegmentTranscriber: SegmentTranscriber {
  /// `prepare()` の結果
  public let preparation: Result<Void, SpeechRecognitionError>
  /// 推論の結果。呼ばれた順に使い、使い切った後は空の結果を返す
  public let results: [Result<[TranscribedSegment], SpeechRecognitionError>]
  private let beforePrepare: @Sendable () async -> Void
  private let beforeTranscribe: @Sendable () async -> Void
  private let state = Mutex(State())

  private struct State {
    var prepareCount = 0
    var transcribedSampleCounts: [Int] = []
    var languages: [String] = []
  }

  public init(
    preparation: Result<Void, SpeechRecognitionError> = .success(()),
    results: [Result<[TranscribedSegment], SpeechRecognitionError>] = [],
    beforePrepare: @escaping @Sendable () async -> Void = {},
    beforeTranscribe: @escaping @Sendable () async -> Void = {}
  ) {
    self.preparation = preparation
    self.results = results
    self.beforePrepare = beforePrepare
    self.beforeTranscribe = beforeTranscribe
  }

  /// `prepare()` が呼ばれた回数
  public var prepareCount: Int {
    state.withLock { $0.prepareCount }
  }

  /// 推論に渡された音声のサンプル数（呼ばれた順）
  public var transcribedSampleCounts: [Int] {
    state.withLock { $0.transcribedSampleCounts }
  }

  /// 推論で指定された言語（呼ばれた順）
  public var languages: [String] {
    state.withLock { $0.languages }
  }

  public func prepare() async throws(SpeechRecognitionError) {
    state.withLock { $0.prepareCount += 1 }
    await beforePrepare()
    try preparation.get()
  }

  public func transcribe(_ samples: [Float], language: String) async throws(SpeechRecognitionError)
    -> [TranscribedSegment]
  {
    let index = state.withLock {
      $0.transcribedSampleCounts.append(samples.count)
      $0.languages.append(language)
      return $0.transcribedSampleCounts.count - 1
    }
    await beforeTranscribe()
    guard index < results.count else {
      return []
    }
    return try results[index].get()
  }
}
