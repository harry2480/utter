import Synchronization
import Testing
import UtterCore

@testable import UtterSpeech

struct WhisperKitRecognizerTests {
  private let session = SessionID()
  static let rate = WhisperKitRecognizerConfiguration.sampleRate

  static func chunk(seconds: Double, sampleRate: Int = rate) -> AudioChunk {
    AudioChunk(
      samples: Array(repeating: 0, count: Int(seconds * Double(sampleRate))), sampleRate: sampleRate
    )
  }

  static func segment(_ text: String, end: Double) -> TranscribedSegment {
    TranscribedSegment(text: text, end: .seconds(end))
  }

  /// 録音済みの音声
  static func audio(_ chunks: [AudioChunk]) -> AsyncStream<AudioChunk> {
    AsyncStream { continuation in
      for chunk in chunks {
        continuation.yield(chunk)
      }
      continuation.finish()
    }
  }

  static func enabled() throws -> WhisperKitRecognizerConfiguration {
    try WhisperKitRecognizerConfiguration(isEnabled: true)
  }

  private func collect(
    _ transcriber: StubSegmentTranscriber,
    configuration: WhisperKitRecognizerConfiguration? = nil,
    audio: AsyncStream<AudioChunk>
  ) async throws -> [RecognitionEvent] {
    let configuration = try configuration ?? Self.enabled()
    let recognizer = WhisperKitRecognizer(transcriber: transcriber, configuration: configuration)
    var events: [RecognitionEvent] = []
    for await event in recognizer.recognize(audio, session: session) {
      events.append(event)
    }
    return events
  }

  @Test("REC-06: 設定が無効（既定）なら、モデルを準備せずに失敗で終える")
  func failsWhenDisabled() async throws {
    let transcriber = StubSegmentTranscriber()

    let events = try await collect(
      transcriber, configuration: .disabled, audio: Self.audio([Self.chunk(seconds: 1)]))

    #expect(events.map(\.kind) == [.failed(.modelUnavailable)])
    #expect(transcriber.prepareCount == 0)
    #expect(transcriber.transcribedSampleCounts.isEmpty)
  }

  @Test("REC-06: モデルを準備できなければ、推論せずに失敗で終える")
  func failsWhenPreparationFails() async throws {
    let transcriber = StubSegmentTranscriber(preparation: .failure(.modelUnavailable))

    let events = try await collect(transcriber, audio: Self.audio([Self.chunk(seconds: 1)]))

    #expect(events.map(\.kind) == [.failed(.modelUnavailable)])
    #expect(transcriber.transcribedSampleCounts.isEmpty)
  }

  /// 推論が始まるたびに次の音声を流す（録音しながら認識する状況）。最後の音声の後に録音を終える
  private func collectLive(
    results: [Result<[TranscribedSegment], SpeechRecognitionError>], chunks: [AudioChunk]
  ) async throws -> (events: [RecognitionEvent], transcriber: StubSegmentTranscriber) {
    let (started, startedContinuation) = AsyncStream.makeStream(of: Void.self)
    let transcriber = StubSegmentTranscriber(
      results: results, beforeTranscribe: { startedContinuation.yield() })
    let recognizer = WhisperKitRecognizer(
      transcriber: transcriber, configuration: try Self.enabled())
    let (audio, audioContinuation) = AsyncStream.makeStream(of: AudioChunk.self)
    let stream = recognizer.recognize(audio, session: session)
    let consumer = Task {
      var events: [RecognitionEvent] = []
      for await event in stream {
        events.append(event)
      }
      return events
    }
    var remaining = chunks[...]
    if let first = remaining.popFirst() {
      audioContinuation.yield(first)
    }
    var iterator = started.makeAsyncIterator()
    while let next = remaining.popFirst() {
      _ = await iterator.next()
      audioContinuation.yield(next)
    }
    audioContinuation.finish()
    let events = await consumer.value
    startedContinuation.finish()
    return (events, transcriber)
  }

  @Test("AC-03: 音声がたまるたびに推論し直して暫定・確定を流し、最後に全体を完了にする")
  func streamsPartialAndConfirmed() async throws {
    let (events, transcriber) = try await collectLive(
      results: [
        .success([Self.segment("明日", end: 1)]),
        .success([
          Self.segment("明日は", end: 1), Self.segment("晴れ", end: 1.5), Self.segment("です", end: 2),
        ]),
        .success([Self.segment("晴れ", end: 0.5), Self.segment("でしょう", end: 1.5)]),
      ],
      chunks: [Self.chunk(seconds: 1), Self.chunk(seconds: 1), Self.chunk(seconds: 0.5)])

    #expect(
      events.map(\.kind) == [
        .partial("明日"), .confirmed("明日は"), .partial("晴れです"), .completed("明日は晴れでしょう"),
      ])
    #expect(events.map(\.sequence) == [0, 1, 2, 3])
    #expect(events.allSatisfy { $0.sessionID == session })
    // 2回目の推論で1秒分を確定して捨てたため、最後の推論は残りの 1.5 秒分
    #expect(transcriber.transcribedSampleCounts == [Self.rate, 2 * Self.rate, Self.rate * 3 / 2])
    #expect(transcriber.languages == ["ja", "ja", "ja"])
    #expect(transcriber.prepareCount == 1)
  }

  @Test("REC-06: 録音済みの音声は途中の推論をせず、最後に1回だけ推論する")
  func transcribesRecordedAudioOnce() async throws {
    let transcriber = StubSegmentTranscriber(results: [.success([Self.segment("全部", end: 2)])])

    let events = try await collect(
      transcriber, audio: Self.audio([Self.chunk(seconds: 1), Self.chunk(seconds: 1)]))

    #expect(events.map(\.kind) == [.completed("全部")])
    #expect(transcriber.transcribedSampleCounts == [2 * Self.rate])
  }

  @Test("REC-06: 音声がなければ推論せずに空の完了にする")
  func completesEmptyWithoutAudio() async throws {
    let transcriber = StubSegmentTranscriber()

    let events = try await collect(transcriber, audio: Self.audio([]))

    #expect(events.map(\.kind) == [.completed("")])
    #expect(transcriber.transcribedSampleCounts.isEmpty)
  }

  @Test("REC-06: 16kHz でない音声が届いたら形式の失敗で終える")
  func failsOnUnsupportedSampleRate() async throws {
    let transcriber = StubSegmentTranscriber()

    let events = try await collect(
      transcriber, audio: Self.audio([Self.chunk(seconds: 1, sampleRate: 44_100)]))

    #expect(events.map(\.kind) == [.failed(.unsupportedAudioFormat)])
    #expect(transcriber.transcribedSampleCounts.isEmpty)
  }

  @Test("REC-06: 推論に失敗したら、その種類の失敗で終える")
  func failsWhenTranscriptionFails() async throws {
    let (events, _) = try await collectLive(
      results: [.success([Self.segment("途中", end: 1)]), .failure(.engineFailed)],
      chunks: [Self.chunk(seconds: 1), Self.chunk(seconds: 1)])

    #expect(events.map(\.kind) == [.partial("途中"), .failed(.engineFailed)])
  }

  @Test("REC-06: 推論中に受け手がストリームを破棄したら、推論を止めて終端イベントを流さない")
  func stopsWhenConsumerCancels() async throws {
    let (started, startedContinuation) = AsyncStream.makeStream(of: Void.self)
    let observedCancellation = Mutex(false)
    let transcriber = StubSegmentTranscriber(
      results: [.success([Self.segment("届かない", end: 1)])],
      beforeTranscribe: {
        startedContinuation.yield()
        // キャンセルされるまで待つ
        try? await Task.sleep(for: .seconds(3600))
        observedCancellation.withLock { $0 = Task.isCancelled }
        startedContinuation.finish()
      })
    let recognizer = WhisperKitRecognizer(
      transcriber: transcriber, configuration: try Self.enabled())
    let (audio, audioContinuation) = AsyncStream.makeStream(of: AudioChunk.self)
    audioContinuation.yield(Self.chunk(seconds: 1))
    let stream = recognizer.recognize(audio, session: session)

    let consumer = Task {
      var events: [RecognitionEvent] = []
      for await event in stream {
        events.append(event)
      }
      return events
    }
    var iterator = started.makeAsyncIterator()
    _ = await iterator.next()
    consumer.cancel()
    let events = await consumer.value
    // 推論の待ちがキャンセルで解けるまで待つ
    while await iterator.next() != nil {}

    #expect(events.isEmpty)
    #expect(observedCancellation.withLock { $0 })
    audioContinuation.yield(Self.chunk(seconds: 1))
    audioContinuation.finish()
    #expect(transcriber.transcribedSampleCounts == [Self.rate])
  }

  @Test("REC-06: モデルの準備中に受け手がストリームを破棄したら、推論せずに終端イベントを流さない")
  func stopsWhenConsumerCancelsDuringPreparation() async throws {
    let (started, startedContinuation) = AsyncStream.makeStream(of: Void.self)
    let transcriber = StubSegmentTranscriber(
      beforePrepare: {
        startedContinuation.yield()
        try? await Task.sleep(for: .seconds(3600))
      })
    let recognizer = WhisperKitRecognizer(
      transcriber: transcriber, configuration: try Self.enabled())
    let stream = recognizer.recognize(Self.audio([Self.chunk(seconds: 1)]), session: session)

    let consumer = Task {
      var events: [RecognitionEvent] = []
      for await event in stream {
        events.append(event)
      }
      return events
    }
    for await _ in started { break }
    consumer.cancel()

    #expect(await consumer.value.isEmpty)
    #expect(transcriber.transcribedSampleCounts.isEmpty)
  }

  @Test("REC-06: 推論中に届いた音声は次の推論でまとめて扱い、録音が終わっていれば最後の推論だけを行う")
  func coalescesAudioReceivedDuringTranscription() async throws {
    let (started, startedContinuation) = AsyncStream.makeStream(of: Void.self)
    let (release, releaseContinuation) = AsyncStream.makeStream(of: Void.self)
    let transcriber = StubSegmentTranscriber(
      results: [.success([Self.segment("途中", end: 1)]), .success([Self.segment("全部", end: 4)])],
      beforeTranscribe: {
        startedContinuation.yield()
        for await _ in release { break }
      })
    let recognizer = WhisperKitRecognizer(
      transcriber: transcriber, configuration: try Self.enabled())
    let (audio, audioContinuation) = AsyncStream.makeStream(of: AudioChunk.self)
    audioContinuation.yield(Self.chunk(seconds: 1))
    let stream = recognizer.recognize(audio, session: session)
    let consumer = Task {
      var events: [RecognitionEvent] = []
      for await event in stream {
        events.append(event)
      }
      return events
    }

    for await _ in started { break }
    // 1回目の推論の間に、残りの音声と録音の終わりが届く
    for _ in 0..<3 {
      audioContinuation.yield(Self.chunk(seconds: 1))
    }
    audioContinuation.finish()
    // 読み込み用のタスクが録音の終わりまで読むのを待ってから、推論を進める
    try await Task.sleep(for: .milliseconds(500))
    releaseContinuation.yield()
    releaseContinuation.finish()
    let events = await consumer.value

    #expect(events.map(\.kind) == [.partial("途中"), .completed("全部")])
    #expect(transcriber.transcribedSampleCounts == [Self.rate, 4 * Self.rate])
  }
}
