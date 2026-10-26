import Synchronization
import Testing
import UtterCore

@testable import UtterSpeech

struct STTWorkerServiceTests {
  /// Worker が返したイベントを受け取る
  private final class Responses: Sendable {
    let stream: AsyncStream<RecognitionEvent>
    private let continuation: AsyncStream<RecognitionEvent>.Continuation

    init() {
      (stream, continuation) = AsyncStream.makeStream(of: RecognitionEvent.self)
    }

    func receive(_ response: STTWorkerResponse) {
      switch response {
      case .event(let event): continuation.yield(event)
      }
    }

    /// 終端イベントまでを集める
    func untilTerminal() async -> [RecognitionEvent] {
      var events: [RecognitionEvent] = []
      for await event in stream {
        events.append(event)
        if event.kind.isTerminal { break }
      }
      return events
    }
  }

  private static func resources(
    _ mode: ModelRetentionMode, performanceAllowed: Bool = false,
    pressure: MemoryPressure = .normal, batteryLow: Bool = false
  ) throws -> STTWorkerResources {
    STTWorkerResources(
      policy: try ModelRetentionPolicy(
        mode: mode, balancedRetention: .seconds(30), performanceRetentionAllowed: performanceAllowed
      ),
      deviceState: DeviceResourceState(memoryPressure: pressure, isBatteryLow: batteryLow))
  }

  private let loader = StubSpeechModelLoader(steps: [.confirmed("明日は")], sleep: { _ in })
  private let sleeper = ManualSleeper()

  private func makeService(
    loaders: [STTEngineKind: any SpeechModelLoader]? = nil
  ) async -> (STTWorkerService, Responses) {
    let sleeper = sleeper
    let service = STTWorkerService(
      loaders: loaders ?? [.stub: loader], sleep: { try await sleeper.sleep($0) })
    let responses = Responses()
    await service.attach { responses.receive($0) }
    return (service, responses)
  }

  /// 1セッションを最後まで認識する
  private func recognizeOnce(
    _ service: STTWorkerService, _ responses: Responses, engine: STTEngineKind = .stub
  ) async -> [RecognitionEvent] {
    let session = SessionID()
    await service.handle(.start(session: session, engine: engine))
    await service.handle(
      .audio(session: session, chunk: AudioChunk(samples: [0], sampleRate: 16_000)))
    await service.handle(.finishAudio(session: session))
    return await responses.untilTerminal()
  }

  @Test("4章: 受け取った音声を認識し、イベントをセッションID と順序番号つきで返す")
  func recognizesSession() async throws {
    let (service, responses) = await makeService()
    let session = SessionID()

    await service.handle(.start(session: session, engine: .stub))
    await service.handle(.finishAudio(session: session))
    let events = await responses.untilTerminal()

    #expect(events.map(\.kind) == [.confirmed("明日は"), .completed("明日は")])
    #expect(events.map(\.sequence) == [0, 1])
    #expect(events.allSatisfy { $0.sessionID == session })
  }

  @Test("11章: 登録のないエンジンは既定のエンジンで代えず、失敗にする")
  func failsForUnregisteredEngine() async {
    let (service, responses) = await makeService()

    let events = await recognizeOnce(service, responses, engine: .whisperKit)

    #expect(events.map(\.kind) == [.failed(.modelUnavailable)])
    #expect(loader.loadCount == 0)
  }

  @Test("4章: モデルのロードに失敗したら、その失敗を返す")
  func reportsLoadFailure() async {
    let failing = StubSpeechModelLoader(steps: [], failure: .modelUnavailable)
    let (service, responses) = await makeService(loaders: [.stub: failing])

    let events = await recognizeOnce(service, responses)

    #expect(events.map(\.kind) == [.failed(.modelUnavailable)])
    #expect(await service.isModelLoaded == false)
  }

  @Test("4章: 認識中に別のセッションを始めたら、後のセッションを失敗にする")
  func rejectsSecondSession() async {
    let waiting = StubSpeechModelLoader(steps: [.partial("あ")], sleep: { _ in })
    let (service, responses) = await makeService(loaders: [.stub: waiting])
    let first = SessionID()
    let second = SessionID()

    await service.handle(.start(session: first, engine: .stub))
    var iterator = responses.stream.makeAsyncIterator()
    #expect(await iterator.next()?.kind == .partial("あ"))
    await service.handle(.start(session: second, engine: .stub))
    let rejected = await iterator.next()

    #expect(rejected?.sessionID == second)
    #expect(rejected?.kind == .failed(.resourceLimited))
  }

  @Test("4章: キャンセルしたセッションは終端イベントを返さずに止める")
  func cancelStopsWithoutTerminalEvent() async throws {
    let (service, responses) = await makeService()
    let session = SessionID()
    let next = SessionID()

    await service.handle(
      .updateResources(try Self.resources(.performance, performanceAllowed: true)))
    await service.handle(.start(session: session, engine: .stub))
    await service.handle(.cancel(session: session))
    // 止めた後は次のセッションを始められる
    await service.handle(.start(session: next, engine: .stub))
    await service.handle(.finishAudio(session: next))
    let events = await responses.untilTerminal()

    #expect(events.filter(\.kind.isTerminal).map(\.sessionID) == [next])
    #expect(loader.loadCount == 1)
  }

  @Test("6章: 保持の設定を受け取る前は、推論後すぐにモデルを解放する")
  func releasesWithoutResources() async {
    let (service, responses) = await makeService()

    _ = await recognizeOnce(service, responses)

    #expect(await service.isModelLoaded == false)
  }

  @Test("6章: 省電力モードは推論後にモデルを解放し、次の推論でロードし直す")
  func powerSavingReleasesAfterInference() async throws {
    let (service, responses) = await makeService()
    await service.handle(.updateResources(try Self.resources(.powerSaving)))

    _ = await recognizeOnce(service, responses)
    #expect(await service.isModelLoaded == false)
    _ = await recognizeOnce(service, responses)

    #expect(loader.loadCount == 2)
  }

  @Test("6章: バランスモードは保持時間だけモデルを残し、その間の推論で使い回す")
  func balancedKeepsModelForRetention() async throws {
    let (service, responses) = await makeService()
    await service.handle(.updateResources(try Self.resources(.balanced)))

    _ = await recognizeOnce(service, responses)
    #expect(await service.isModelLoaded)
    #expect(await eventually { sleeper.durations == [.seconds(30)] })
    _ = await recognizeOnce(service, responses)
    #expect(loader.loadCount == 1)

    // 2回目の推論の後に予約し直した解放だけが効く
    #expect(await eventually { sleeper.waiterCount == 2 })
    sleeper.resumeAll()
    #expect(await eventually { await service.isModelLoaded == false })
  }

  @Test("6章: 保持時間の間に設定が変わったら、予約していた解放を取り消して判定し直す")
  func stateChangeReschedulesRelease() async throws {
    let (service, responses) = await makeService()
    await service.handle(.updateResources(try Self.resources(.balanced)))
    _ = await recognizeOnce(service, responses)
    #expect(await eventually { sleeper.waiterCount == 1 })

    await service.handle(
      .updateResources(try Self.resources(.performance, performanceAllowed: true)))
    sleeper.resumeAll()
    for _ in 0..<100 { await Task.yield() }

    #expect(await service.isModelLoaded)
  }

  @Test("6章: 高速モードは状態が変わるまで保持し、低バッテリーでも解放しない")
  func performanceKeepsUntilStateChanges() async throws {
    let (service, responses) = await makeService()
    await service.handle(
      .updateResources(try Self.resources(.performance, performanceAllowed: true)))

    _ = await recognizeOnce(service, responses)
    await service.handle(
      .updateResources(try Self.resources(.performance, performanceAllowed: true, batteryLow: true))
    )

    #expect(await service.isModelLoaded)
    #expect(sleeper.durations.isEmpty)
  }

  @Test(
    "AC-11: 保持中にメモリ圧迫が届いたら、どのモードでもモデルを解放する",
    arguments: [MemoryPressure.warning, .critical])
  func releasesOnMemoryPressure(_ pressure: MemoryPressure) async throws {
    let (service, responses) = await makeService()
    await service.handle(
      .updateResources(try Self.resources(.performance, performanceAllowed: true)))
    _ = await recognizeOnce(service, responses)

    await service.handle(
      .updateResources(
        try Self.resources(.performance, performanceAllowed: true, pressure: pressure)))

    #expect(await service.isModelLoaded == false)
  }

  @Test("AC-11: メモリ圧迫時は高負荷モデルをロードせず、失敗にする")
  func defersHeavyModelUnderMemoryPressure() async throws {
    let heavy = StubSpeechModelLoader(weight: .heavy, steps: [], sleep: { _ in })
    let (service, responses) = await makeService(loaders: [.whisperKit: heavy])
    await service.handle(.updateResources(try Self.resources(.balanced, pressure: .warning)))

    let events = await recognizeOnce(service, responses, engine: .whisperKit)

    #expect(events.map(\.kind) == [.failed(.resourceLimited)])
    #expect(heavy.loadCount == 0)
  }

  @Test("4章: 別のエンジンを使うときは、ロード済みのモデルを解放してからロードする")
  func switchesEngine() async throws {
    let other = StubSpeechModelLoader(steps: [], sleep: { _ in })
    let (service, responses) = await makeService(loaders: [.stub: loader, .speechAnalyzer: other])
    await service.handle(
      .updateResources(try Self.resources(.performance, performanceAllowed: true)))

    _ = await recognizeOnce(service, responses, engine: .stub)
    _ = await recognizeOnce(service, responses, engine: .speechAnalyzer)

    #expect(await service.loadedEngine == .speechAnalyzer)
    #expect(loader.loadCount == 1)
    #expect(other.loadCount == 1)
  }

  @Test("AC-10: 接続が切れたら認識を止めてモデルを解放する")
  func runReleasesWhenConnectionEnds() async throws {
    let service = STTWorkerService(loaders: [.stub: loader], sleep: { _ in })
    let (incoming, continuation) = AsyncStream.makeStream(of: STTWorkerRequest.self)
    let responses = Responses()
    let run = Task { await service.run(incoming: incoming) { responses.receive($0) } }

    continuation.yield(.updateResources(try Self.resources(.performance, performanceAllowed: true)))
    let session = SessionID()
    continuation.yield(.start(session: session, engine: .stub))
    continuation.yield(.finishAudio(session: session))
    _ = await responses.untilTerminal()
    #expect(await service.isModelLoaded)

    continuation.finish()
    await run.value

    #expect(await service.isModelLoaded == false)
  }
}
