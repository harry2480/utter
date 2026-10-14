import Synchronization
import Testing
import UtterCore

@testable import UtterSpeech

struct StubSpeechRecognizerTests {
  private let session = SessionID()

  /// すぐに終わる（録音済みの）音声
  private static func finishedAudio() -> AsyncStream<AudioChunk> {
    AsyncStream { $0.finish() }
  }

  private func collect(
    _ recognizer: StubSpeechRecognizer,
    audio: AsyncStream<AudioChunk> = finishedAudio()
  ) async -> [RecognitionEvent] {
    var events: [RecognitionEvent] = []
    for await event in recognizer.recognize(audio, session: session) {
      events.append(event)
    }
    return events
  }

  @Test("REC-06: 固定のイベント列をセッションID と順序番号つきで流す")
  func emitsScriptedEvents() async {
    let recognizer = StubSpeechRecognizer(
      steps: [.partial("あし"), .confirmed("明日は"), .partial("はれ"), .completed("明日は晴れ")],
      sleep: { _ in })

    let events = await collect(recognizer)

    #expect(
      events.map(\.kind) == [
        .partial("あし"), .confirmed("明日は"), .partial("はれ"), .completed("明日は晴れ"),
      ])
    #expect(events.map(\.sequence) == [0, 1, 2, 3])
    #expect(events.allSatisfy { $0.sessionID == session })
  }

  @Test(
    "REC-06: どの手順でも終端イベントを最後に1回だけ流す",
    arguments: [
      [StubSpeechRecognizer.Step.partial("a")],
      [.confirmed("a"), .completed("a"), .partial("b")],
      [.fail(.engineFailed), .completed("a")],
      [.delay(.seconds(1)), .confirmed("a")],
      [],
    ])
  func emitsExactlyOneTerminalEvent(_ steps: [StubSpeechRecognizer.Step]) async {
    let events = await collect(StubSpeechRecognizer(steps: steps, sleep: { _ in }))

    #expect(events.count(where: \.kind.isTerminal) == 1)
    #expect(events.last?.kind.isTerminal == true)
  }

  @Test("REC-06: 完了を含まない手順は、音声が終わってから確定テキストを連結して完了する")
  func completesAfterAudioEnds() async {
    let recognizer = StubSpeechRecognizer(
      steps: [.confirmed("明日は"), .confirmed("晴れ")], sleep: { _ in })
    let (audio, producer) = AsyncStream.makeStream(of: AudioChunk.self)
    var iterator = recognizer.recognize(audio, session: session).makeAsyncIterator()

    #expect(await iterator.next()?.kind == .confirmed("明日は"))
    #expect(await iterator.next()?.kind == .confirmed("晴れ"))
    producer.yield(AudioChunk(samples: [0], sampleRate: 16_000))
    producer.finish()

    #expect(await iterator.next()?.kind == .completed("明日は晴れ"))
    #expect(await iterator.next() == nil)
  }

  @Test("REC-06: 認識中は音声のストリームを保持し、録音側が終えるまで切らない")
  func keepsAudioUntilProducerFinishes() async {
    let reasons = Mutex<[String]>([])
    let (audio, producer) = AsyncStream.makeStream(of: AudioChunk.self)
    producer.onTermination = { reason in
      reasons.withLock { $0.append(String(describing: reason)) }
    }
    let recognizer = StubSpeechRecognizer(steps: [.partial("a")], sleep: { _ in })
    let events = recognizer.recognize(audio, session: session)

    producer.yield(AudioChunk(samples: [0, 0], sampleRate: 16_000))
    producer.finish()
    var received: [RecognitionEvent.Kind] = []
    for await event in events {
      received.append(event.kind)
    }

    #expect(received == [.partial("a"), .completed("")])
    #expect(reasons.withLock { $0 } == ["finished"])
  }

  @Test("REC-06: 失敗を注入すると failed で終わり、以降の手順は流さない", arguments: SpeechRecognitionError.allCases)
  func injectsFailure(_ error: SpeechRecognitionError) async {
    let recognizer = StubSpeechRecognizer(
      steps: [.partial("あ"), .fail(error), .completed("流さない")], sleep: { _ in })

    let events = await collect(recognizer)

    #expect(events.map(\.kind) == [.partial("あ"), .failed(error)])
  }

  @Test("REC-06: 遅延は注入した sleep で待ち、実時間を待たない")
  func delaysWithInjectedSleep() async {
    let recorded = Mutex<[Duration]>([])
    let recognizer = StubSpeechRecognizer(
      steps: [.delay(.seconds(5)), .partial("a"), .delay(.milliseconds(300)), .completed("a")],
      sleep: { duration in recorded.withLock { $0.append(duration) } })

    let events = await collect(recognizer)

    #expect(recorded.withLock { $0 } == [.seconds(5), .milliseconds(300)])
    #expect(events.count == 2)
  }

  @Test("REC-06: キャンセル以外で sleep が失敗したら failed(engineFailed) で終える")
  func sleepFailureEndsWithFailed() async {
    struct SleepFailure: Error {}
    let recognizer = StubSpeechRecognizer(
      steps: [.partial("a"), .delay(.seconds(1)), .partial("b")],
      sleep: { _ in throw SleepFailure() })

    let events = await collect(recognizer)

    #expect(events.map(\.kind) == [.partial("a"), .failed(.engineFailed)])
  }

  @Test("REC-01: 受け手がストリームを破棄すると認識を止め、以降のイベントを流さない", .timeLimit(.minutes(1)))
  func stopsWhenConsumerCancels() async {
    let (cancellations, signal) = AsyncStream.makeStream(of: Void.self)
    let emittedAfterCancel = Mutex(false)
    let recognizer = StubSpeechRecognizer(
      steps: [.partial("a"), .delay(.seconds(60)), .partial("b")],
      sleep: { _ in
        // キャンセルされるまで待ち、キャンセルを合図で知らせる
        let (never, _) = AsyncStream.makeStream(of: Void.self)
        await withTaskCancellationHandler {
          for await _ in never {}
        } onCancel: {
          signal.yield()
          signal.finish()
        }
        emittedAfterCancel.withLock { $0 = !Task.isCancelled }
        throw CancellationError()
      })

    var received: [RecognitionEvent.Kind] = []
    for await event in recognizer.recognize(Self.finishedAudio(), session: session) {
      received.append(event.kind)
      break
    }

    // 破棄によって sleep がキャンセルされるまで待つ（実時間の待機は使わない）
    var iterator = cancellations.makeAsyncIterator()
    await iterator.next()
    #expect(received == [.partial("a")])
    #expect(!emittedAfterCancel.withLock { $0 })
  }

  @Test("REC-06: 手順の文字列表現に認識テキストを含めない")
  func redactsSteps() {
    let steps: [StubSpeechRecognizer.Step] = [
      .partial("秘密"), .confirmed("秘密"), .completed("秘密"), .fail(.engineFailed),
      .delay(.seconds(1)),
    ]

    for step in steps {
      #expect(!String(describing: step).contains("秘密"))
      #expect(!String(reflecting: step).contains("秘密"))
    }
    #expect(String(describing: steps[0]) == "partial(length: 2)")
  }
}
