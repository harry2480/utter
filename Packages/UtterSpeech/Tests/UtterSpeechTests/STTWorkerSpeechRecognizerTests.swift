import Synchronization
import Testing
import UtterCore

@testable import UtterSpeech

struct STTWorkerSpeechRecognizerTests {
  /// 異常終了の通知を受け取る
  private final class Terminations: Sendable {
    let stream: AsyncStream<STTWorkerTermination>
    private let continuation: AsyncStream<STTWorkerTermination>.Continuation

    init() {
      (stream, continuation) = AsyncStream.makeStream(of: STTWorkerTermination.self)
    }

    func record(_ termination: STTWorkerTermination) {
      continuation.yield(termination)
    }

    func next() async -> STTWorkerTermination? {
      var iterator = stream.makeAsyncIterator()
      return await iterator.next()
    }
  }

  private let sleeper = ManualSleeper()
  private let terminations = Terminations()

  /// 確定テキストを1つ流し、音声の終わりで完了する Worker。`hangs` なら認識の途中で止まり続ける
  private func makeConnector(
    hangs: Bool = false, failure: STTWorkerConnectionError? = nil
  ) -> StubSTTWorkerConnector {
    let sleeper = sleeper
    let steps: [StubSpeechRecognizer.Step] =
      hangs ? [.partial("あし"), .delay(.seconds(60))] : [.confirmed("明日は")]
    return StubSTTWorkerConnector(failure: failure) {
      STTWorkerService(
        loaders: [
          .stub: StubSpeechModelLoader(steps: steps, sleep: { try await sleeper.sleep($0) })
        ],
        sleep: { try await sleeper.sleep($0) })
    }
  }

  private func makeRecognizer(
    _ connector: StubSTTWorkerConnector, engine: STTEngineKind? = .stub, restartLimit: Int = 2
  ) -> STTWorkerSpeechRecognizer {
    let terminations = terminations
    return STTWorkerSpeechRecognizer(
      engine: engine, connector: connector, restartLimit: restartLimit,
      onTermination: { terminations.record($0) })
  }

  private static func finishedAudio(_ chunks: [AudioChunk] = []) -> AsyncStream<AudioChunk> {
    AsyncStream { continuation in
      for chunk in chunks { continuation.yield(chunk) }
      continuation.finish()
    }
  }

  private func collect(
    _ recognizer: STTWorkerSpeechRecognizer, session: SessionID = SessionID(),
    audio: AsyncStream<AudioChunk> = finishedAudio()
  ) async -> [RecognitionEvent] {
    var events: [RecognitionEvent] = []
    for await event in recognizer.recognize(audio, session: session) {
      events.append(event)
    }
    return events
  }

  /// 待ち時間の手順を進め続けながら、認識を最後まで集める（起動し直した Worker の認識を完了させる）
  private func collectResumingSleeps(_ recognizer: STTWorkerSpeechRecognizer) async
    -> [RecognitionEvent]
  {
    let sleeper = sleeper
    let resumer = Task {
      while !Task.isCancelled {
        sleeper.resumeAll()
        await Task.yield()
      }
    }
    defer { resumer.cancel() }
    return await collect(recognizer)
  }

  /// 認識の途中（暫定結果を受け取った時点）で Worker を異常終了させ、残りのイベントを集める
  private func terminateMidSession(
    _ recognizer: STTWorkerSpeechRecognizer, _ connector: StubSTTWorkerConnector,
    session: SessionID = SessionID(), with event: STTWorkerConnectionEvent = .interrupted
  ) async -> [RecognitionEvent] {
    let (audio, producer) = AsyncStream.makeStream(of: AudioChunk.self)
    var iterator = recognizer.recognize(audio, session: session).makeAsyncIterator()
    var events: [RecognitionEvent] = []
    if let first = await iterator.next() {
      events.append(first)
    }
    connector.connections.last?.simulateTermination(event)
    while let event = await iterator.next() {
      events.append(event)
    }
    producer.finish()
    return events
  }

  @Test("11章: エンジンが未選択なら Worker を起動せず、失敗にする")
  func doesNotLaunchWorkerWithoutEngine() async {
    let connector = makeConnector()

    let events = await collect(makeRecognizer(connector, engine: nil))

    #expect(events.map(\.kind) == [.failed(.modelUnavailable)])
    #expect(connector.connections.isEmpty)
  }

  @Test("4章: 音声を Worker へ送り、Worker のイベントをそのまま流す")
  func relaysAudioAndEvents() async {
    let connector = makeConnector()
    let recognizer = makeRecognizer(connector)
    let session = SessionID()
    let chunk = AudioChunk(samples: [0.25, -0.5], sampleRate: 16_000)

    let events = await collect(recognizer, session: session, audio: Self.finishedAudio([chunk]))

    #expect(events.map(\.kind) == [.confirmed("明日は"), .completed("明日は")])
    #expect(events.map(\.sequence) == [0, 1])
    #expect(events.allSatisfy { $0.sessionID == session })
    #expect(
      connector.connections.first?.sentRequests == [
        .start(session: session, engine: .stub), .audio(session: session, chunk: chunk),
        .finishAudio(session: session),
      ])
    #expect(await recognizer.state == .connected)
  }

  @Test("6章: 待機中は Worker を起動せず、最初の認識で起動して使い回す")
  func launchesWorkerLazilyAndReusesIt() async {
    let connector = makeConnector()
    let recognizer = makeRecognizer(connector)
    #expect(await recognizer.state == .idle)
    #expect(connector.connections.isEmpty)

    _ = await collect(recognizer)
    _ = await collect(recognizer)

    #expect(connector.connections.count == 1)
  }

  @Test(
    "AC-10: 認識中に Worker が異常終了したら、セッションを失敗にして再処理へ知らせる",
    arguments: [STTWorkerConnectionEvent.interrupted, .invalidated])
  func failsSessionOnTermination(_ termination: STTWorkerConnectionEvent) async {
    let connector = makeConnector(hangs: true)
    let recognizer = makeRecognizer(connector)
    let session = SessionID()

    let events = await terminateMidSession(
      recognizer, connector, session: session, with: termination)

    #expect(events.map(\.kind) == [.partial("あし"), .failed(.engineFailed)])
    #expect(events.map(\.sequence) == [0, 1])
    #expect(await terminations.next() == STTWorkerTermination(session: session, canRestart: true))
    #expect(
      await recognizer.termination(of: session)
        == STTWorkerTermination(session: session, canRestart: true))
    #expect(await recognizer.termination(of: SessionID()) == nil)
    #expect(await recognizer.state == .idle)
    #expect(await recognizer.consecutiveFailures == 1)
    #expect(connector.connections.first?.isInvalidated == true)
    sleeper.resumeAll()
  }

  @Test("AC-10: 受け手が異常終了の失敗を受け取った時点で、異常終了したセッションとして答えられる")
  func answersTerminationWhenFailureArrives() async {
    let connector = makeConnector(hangs: true)
    let recognizer = makeRecognizer(connector, restartLimit: 0)
    let session = SessionID()

    let events = await terminateMidSession(recognizer, connector, session: session)

    // onTermination を待たずに問い合わせる
    #expect(events.last?.kind == .failed(.engineFailed))
    #expect(
      await recognizer.termination(of: session)
        == STTWorkerTermination(session: session, canRestart: false))
    _ = await terminations.next()
    sleeper.resumeAll()
  }

  @Test("AC-10: 異常終了の後は、次の認識で Worker を起動し直し、成功したら回数を戻す")
  func restartsWorkerOnNextRecognition() async {
    let connector = makeConnector(hangs: true)
    let recognizer = makeRecognizer(connector)
    _ = await terminateMidSession(recognizer, connector)
    _ = await terminations.next()

    // 再処理（同じセッションで認識し直す）。新しい Worker で遅延の手順を進めて完了させる
    let events = await collectResumingSleeps(recognizer)

    #expect(connector.connections.count == 2)
    #expect(events.last?.kind == .completed(""))
    #expect(await recognizer.consecutiveFailures == 0)
  }

  @Test("AC-10: 異常終了が回数制限を超えて続いたら、Worker を起動しない")
  func stopsRestartingAfterLimit() async {
    let connector = makeConnector(hangs: true)
    let recognizer = makeRecognizer(connector, restartLimit: 1)

    _ = await terminateMidSession(recognizer, connector)
    #expect(await terminations.next()?.canRestart == true)
    _ = await terminateMidSession(recognizer, connector)
    #expect(await terminations.next()?.canRestart == false)
    #expect(await recognizer.state == .restartLimitReached)

    let events = await collect(recognizer)

    #expect(events.map(\.kind) == [.failed(.engineFailed)])
    #expect(connector.connections.count == 2)

    // 利用者が再試行を選んだら、もう一度起動する
    await recognizer.resetRestartLimit()
    #expect(await recognizer.state == .idle)
    _ = await collectResumingSleeps(recognizer)
    #expect(connector.connections.count == 3)
  }

  @Test("AC-10: 待機中の Worker の終了は異常終了として数えない")
  func idleTerminationIsNotCounted() async {
    let connector = makeConnector()
    let recognizer = makeRecognizer(connector)
    _ = await collect(recognizer)

    connector.connections.first?.simulateTermination(.interrupted)

    #expect(await eventually { await recognizer.state == .idle })
    #expect(await recognizer.consecutiveFailures == 0)
    _ = await collect(recognizer)
    #expect(connector.connections.count == 2)
  }

  @Test("AC-10: Worker に接続できなければ、セッションを失敗にして回数に数え、再処理は知らせない")
  func failsWhenWorkerUnavailable() async {
    let connector = makeConnector(failure: .unavailable)
    let recognizer = makeRecognizer(connector, restartLimit: 0)
    let session = SessionID()

    let events = await collect(recognizer, session: session)

    #expect(events.map(\.kind) == [.failed(.engineFailed)])
    #expect(await recognizer.consecutiveFailures == 1)
    #expect(await recognizer.state == .restartLimitReached)
    #expect(await recognizer.termination(of: session) == nil)
    let notified = Task { await terminations.next() }
    for _ in 0..<100 { await Task.yield() }
    notified.cancel()
    #expect(await notified.value == nil)
  }

  @Test("4章: 受け手が破棄した直後に次のセッションを始めても、破棄したセッションを止めてから始める")
  func startsNextSessionRightAfterDrop() async {
    let connector = makeConnector(hangs: true)
    let recognizer = makeRecognizer(connector)
    let dropped = SessionID()
    let (audio, producer) = AsyncStream.makeStream(of: AudioChunk.self)
    do {
      var iterator = recognizer.recognize(audio, session: dropped).makeAsyncIterator()
      #expect(await iterator.next()?.kind == .partial("あし"))
    }
    // ストリームと受け手を手放した直後（cancel が actor に届く前でもよい）に次を始める
    let next = SessionID()
    var iterator = recognizer.recognize(Self.finishedAudio(), session: next).makeAsyncIterator()
    let first = await iterator.next()

    #expect(first?.sessionID == next)
    #expect(first?.kind == .partial("あし"))
    let sent = connector.connections.first?.sentRequests ?? []
    let cancelIndex = sent.firstIndex(of: .cancel(session: dropped))
    let startIndex = sent.firstIndex(of: .start(session: next, engine: .stub))
    #expect(cancelIndex != nil && startIndex != nil && cancelIndex! < startIndex!)
    producer.finish()
    sleeper.resumeAll()
  }

  @Test("4章: 受け手がストリームを破棄したら、Worker の認識を止める")
  func cancelsWorkerSessionWhenConsumerDrops() async {
    let connector = makeConnector(hangs: true)
    let recognizer = makeRecognizer(connector)
    let session = SessionID()
    let (audio, producer) = AsyncStream.makeStream(of: AudioChunk.self)

    let consumer = Task {
      for await _ in recognizer.recognize(audio, session: session) {}
    }
    #expect(await eventually { connector.connections.first?.sentRequests.isEmpty == false })
    consumer.cancel()
    await consumer.value

    #expect(
      await eventually {
        connector.connections.first?.sentRequests.last == .cancel(session: session)
      })
    producer.finish()
    sleeper.resumeAll()
  }

  @Test("4章: 認識中に別のセッションを始めたら、後のセッションを失敗にする")
  func rejectsConcurrentSession() async {
    let connector = makeConnector(hangs: true)
    let recognizer = makeRecognizer(connector)
    let (audio, producer) = AsyncStream.makeStream(of: AudioChunk.self)
    var first = recognizer.recognize(audio, session: SessionID()).makeAsyncIterator()
    #expect(await first.next()?.kind == .partial("あし"))

    let events = await collect(recognizer)

    #expect(events.map(\.kind) == [.failed(.resourceLimited)])
    producer.finish()
    sleeper.resumeAll()
  }

  @Test("6章: 保持の設定を Worker へ送り、起動し直した Worker にも送り直す")
  func resendsResourcesAfterRestart() async throws {
    let connector = makeConnector(hangs: true)
    let recognizer = makeRecognizer(connector)
    let resources = STTWorkerResources(
      policy: try ModelRetentionPolicy(mode: .powerSaving), deviceState: DeviceResourceState())
    await recognizer.updateResources(resources)
    #expect(connector.connections.isEmpty)

    _ = await terminateMidSession(recognizer, connector)
    _ = await collectResumingSleeps(recognizer)

    #expect(connector.connections.count == 2)
    for connection in connector.connections {
      #expect(connection.sentRequests.first == .updateResources(resources))
    }
  }
}
