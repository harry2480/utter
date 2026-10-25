import Synchronization
import Testing
import UtterCore

@testable import UtterSpeech

struct RecordedAudioRecognitionTests {
  private let session = SessionID()

  private func recorded(_ samples: [Float] = [0.1, 0.2, 0.3, 0.4, 0.5]) throws -> RecordedAudio {
    var audio = try RecordedAudio(sampleRate: 4)
    try audio.append(AudioChunk(samples: samples, sampleRate: 4))
    return audio
  }

  /// 受け取った音声を最後まで読んでから、決めたイベントを流す認識
  private final class ScriptedRecognizer: SpeechRecognizer {
    let received = Mutex<[AudioChunk]>([])
    let sessions = Mutex<[SessionID]>([])
    let events: @Sendable (SessionID) -> [RecognitionEvent]

    init(events: @escaping @Sendable (SessionID) -> [RecognitionEvent]) {
      self.events = events
    }

    func recognize(
      _ audio: AsyncStream<AudioChunk>, session: SessionID
    ) -> AsyncStream<RecognitionEvent> {
      sessions.withLock { $0.append(session) }
      let (stream, continuation) = AsyncStream.makeStream(of: RecognitionEvent.self)
      Task {
        for await chunk in audio {
          self.received.withLock { $0.append(chunk) }
        }
        for event in self.events(session) {
          continuation.yield(event)
        }
        continuation.finish()
      }
      return stream
    }
  }

  @Test("AC-10: 録音済みの音声を最後まで流し、完了したら確定テキストを返す")
  func completesWithRecordedAudio() async throws {
    let recognizer = StubSpeechRecognizer(
      steps: [.partial("あし"), .confirmed("明日は"), .confirmed("晴れ")], sleep: { _ in })

    let result = await recognizer.recognizeAgain(try recorded(), session: session)

    #expect(result == .completed("明日は晴れ"))
  }

  @Test("AC-10: 音声はすべてのチャンクを渡し、元のセッションID で認識する")
  func streamsAllChunksWithSameSession() async throws {
    let audio = try recorded()
    let recognizer = ScriptedRecognizer(events: { session in
      [RecognitionEvent(sessionID: session, sequence: 0, kind: .completed("a"))]
    })

    let result = await recognizer.recognizeAgain(
      audio, session: session, chunkDuration: .milliseconds(500))

    #expect(result == .completed("a"))
    #expect(recognizer.sessions.withLock { $0 } == [session])
    #expect(recognizer.received.withLock { $0 } == audio.chunks(chunkDuration: .milliseconds(500)))
  }

  @Test("AC-10: 同じセッションID でやり直すたびに、順序番号 0 からのイベントを受け付ける")
  func acceptsRestartedSequence() async throws {
    let audio = try recorded()
    let recognizer = StubSpeechRecognizer(steps: [.partial("a"), .completed("a")], sleep: { _ in })

    let first = await recognizer.recognizeAgain(audio, session: session)
    let second = await recognizer.recognizeAgain(audio, session: session)

    #expect(first == .completed("a"))
    #expect(second == .completed("a"))
  }

  @Test("AC-10: 別のセッションや順序の古いイベントは受け付けない")
  func filtersEvents() async throws {
    let other = SessionID()
    let recognizer = ScriptedRecognizer(events: { session in
      [
        RecognitionEvent(sessionID: other, sequence: 0, kind: .completed("別")),
        RecognitionEvent(sessionID: session, sequence: 1, kind: .partial("a")),
        RecognitionEvent(sessionID: session, sequence: 1, kind: .completed("古い")),
        RecognitionEvent(sessionID: session, sequence: 2, kind: .completed("正")),
      ]
    })

    let result = await recognizer.recognizeAgain(try recorded(), session: session)

    #expect(result == .completed("正"))
  }

  @Test("AC-10: 認識が失敗したら、その種類を返す", arguments: SpeechRecognitionError.allCases)
  func returnsFailure(_ error: SpeechRecognitionError) async throws {
    let recognizer = StubSpeechRecognizer(steps: [.partial("a"), .fail(error)], sleep: { _ in })

    let result = await recognizer.recognizeAgain(try recorded(), session: session)

    #expect(result == .failed(error))
  }

  @Test("AC-10: 終端イベントなしに認識が終わったら、エンジンの失敗として返す")
  func endsWithoutTerminalEvent() async throws {
    let recognizer = ScriptedRecognizer(events: { session in
      [RecognitionEvent(sessionID: session, sequence: 0, kind: .partial("a"))]
    })

    let result = await recognizer.recognizeAgain(try recorded(), session: session)

    #expect(result == .failed(.engineFailed))
  }

  @Test("AC-10: キャンセルされたら認識を止め、cancelled を返す", .timeLimit(.minutes(1)))
  func cancels() async throws {
    let (started, signal) = AsyncStream.makeStream(of: Void.self)
    let recognizer = StubSpeechRecognizer(
      steps: [.partial("a"), .delay(.seconds(60)), .completed("流さない")],
      sleep: { _ in
        signal.yield()
        // キャンセルされるまで待つ（実時間の待機は使わない）
        let (never, _) = AsyncStream.makeStream(of: Void.self)
        for await _ in never {}
        throw CancellationError()
      })
    let audio = try recorded()
    let session = session

    let task = Task { await recognizer.recognizeAgain(audio, session: session) }
    var iterator = started.makeAsyncIterator()
    await iterator.next()
    task.cancel()

    #expect(await task.value == .cancelled)
  }

  @Test("AC-10: 結果の文字列表現に認識テキストを含めない")
  func redactsResult() {
    let result = RecordedAudioRecognitionResult.completed("秘密")

    #expect(String(describing: result) == "completed(length: 2)")
    #expect(!String(reflecting: result).contains("秘密"))
  }
}
