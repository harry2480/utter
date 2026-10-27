import AVFoundation
import Foundation
import Speech
import Synchronization
import Testing
import UtterCore

@testable import UtterSpeech

/// 解析器の呼び出しを記録し、結果を外から流せる `TranscriptionSession`。
private final class StubTranscriptionSession: TranscriptionSession {
  enum Call: Hashable, Sendable {
    case prepare, start, finalize, cancel
  }

  /// Float32 の形式のバッファを `AnalyzerInput(buffer:)` に渡すとテスト中にトラップしたため、Probe で SpeechAnalyzer が返した形式と同じ Int16 16kHz にする
  let audioFormat: AVAudioFormat
  private let prepareError: (any Error & Sendable)?
  private let startError: (any Error & Sendable)?
  private let finalizeError: (any Error & Sendable)?
  /// `finalize()` で流してから結果を終える確定結果
  private let finalSegments: [TranscriptionSegment]
  /// `prepare()` を、タスクのキャンセルでは戻らず `cancel()` が呼ばれるまで待たせる
  private let blocksPrepare: Bool
  private let stream: AsyncThrowingStream<TranscriptionSegment, any Error>
  private let continuation: AsyncThrowingStream<TranscriptionSegment, any Error>.Continuation
  private let state = Mutex<(calls: [Call], waiter: CheckedContinuation<Void, Never>?)>(([], nil))

  init(
    prepareError: (any Error & Sendable)? = nil, startError: (any Error & Sendable)? = nil,
    finalizeError: (any Error & Sendable)? = nil, finalSegments: [TranscriptionSegment] = [],
    blocksPrepare: Bool = false
  ) throws {
    audioFormat = try #require(
      AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false))
    self.prepareError = prepareError
    self.startError = startError
    self.finalizeError = finalizeError
    self.finalSegments = finalSegments
    self.blocksPrepare = blocksPrepare
    (stream, continuation) = AsyncThrowingStream.makeStream(
      of: TranscriptionSegment.self, throwing: (any Error).self)
  }

  var calls: [Call] { state.withLock { $0.calls } }

  private func record(_ call: Call) {
    state.withLock { $0.calls.append(call) }
  }

  func prepare() async throws {
    record(.prepare)
    if blocksPrepare {
      // タスクのキャンセルには応じず、cancel() だけで戻る（応じない OS の呼び出しを模す）
      await withCheckedContinuation { waiter in
        let cancelled = state.withLock { state in
          if state.calls.contains(.cancel) { return true }
          state.waiter = waiter
          return false
        }
        if cancelled { waiter.resume() }
      }
      throw CancellationError()
    }
    if let prepareError { throw prepareError }
  }

  func start(_ inputs: AsyncStream<AnalyzerInput>) async throws {
    record(.start)
    if let startError { throw startError }
  }

  func results() -> AsyncThrowingStream<TranscriptionSegment, any Error> { stream }

  func finalize() async throws {
    record(.finalize)
    if let finalizeError { throw finalizeError }
    for segment in finalSegments { continuation.yield(segment) }
    continuation.finish()
  }

  func cancel() async {
    let waiter = state.withLock { state in
      state.calls.append(.cancel)
      defer { state.waiter = nil }
      return state.waiter
    }
    waiter?.resume()
    continuation.finish()
  }

  /// 解析器が結果を出したことにする
  func yield(_ segment: TranscriptionSegment) { continuation.yield(segment) }

  /// 結果のストリームを終える。`error` があれば失敗で終える
  func finishResults(throwing error: (any Error)? = nil) { continuation.finish(throwing: error) }
}

struct TranscriptionRunTests {
  private let session = SessionID()

  private static func chunk(sampleRate: Int = 16_000) -> AudioChunk {
    AudioChunk(samples: [Float](repeating: 0.1, count: 160), sampleRate: sampleRate)
  }

  private static func segment(_ text: String, isFinal: Bool, start: Double = 0, end: Double = 1)
    -> TranscriptionSegment
  {
    TranscriptionSegment(
      isFinal: isFinal, runs: [TranscriptionSegment.Run(text: text, start: start)], end: end)
  }

  private func events(
    _ stub: StubTranscriptionSession, audio: AsyncStream<AudioChunk>
  ) -> AsyncStream<RecognitionEvent> {
    TranscriptionRun.events(audio: audio, session: session) { .success(stub) }
  }

  private static func collect(_ events: AsyncStream<RecognitionEvent>) async -> [RecognitionEvent] {
    var collected: [RecognitionEvent] = []
    for await event in events { collected.append(event) }
    return collected
  }

  /// 条件が成り立つまで待つ（並行して進む認識の呼び出しを待つため。上限つき）
  private static func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<2_000 where !condition() {
      try await Task.sleep(for: .milliseconds(1))
    }
    #expect(condition())
  }

  @Test("REC-06: 暫定・確定結果を流し、音声の終わりで確定させて全体を completed で流す")
  func completesAfterAudioEnds() async throws {
    let stub = try StubTranscriptionSession(
      finalSegments: [Self.segment("晴れ", isFinal: true, start: 1, end: 2)])
    let (audio, input) = AsyncStream.makeStream(of: AudioChunk.self)
    let events = events(stub, audio: audio)
    stub.yield(Self.segment("あした", isFinal: false))
    stub.yield(Self.segment("明日は", isFinal: true))
    input.yield(Self.chunk())
    input.finish()

    let collected = await Self.collect(events)

    #expect(
      collected.map(\.kind) == [
        .partial("あした"), .confirmed("明日は"), .confirmed("晴れ"), .completed("明日は晴れ"),
      ])
    #expect(collected.map(\.sequence) == [0, 1, 2, 3])
    #expect(collected.allSatisfy { $0.sessionID == session })
    #expect(stub.calls == [.prepare, .start, .finalize])
  }

  @Test("#48: 確定されないまま残った末尾の暫定結果を completed の末尾に含める。confirmed は変えない")
  func completedKeepsUnfinalizedTail() async throws {
    let stub = try StubTranscriptionSession()
    let (audio, input) = AsyncStream.makeStream(of: AudioChunk.self)
    let events = events(stub, audio: audio)
    stub.yield(Self.segment("明日は", isFinal: true))
    stub.yield(Self.segment("晴れです", isFinal: false, start: 1, end: 2))
    input.yield(Self.chunk())
    input.finish()

    let collected = await Self.collect(events)

    #expect(collected.map(\.kind) == [.confirmed("明日は"), .partial("晴れです"), .completed("明日は晴れです")])
    #expect(stub.calls == [.prepare, .start, .finalize])
  }

  @Test("#48: 末尾の暫定結果が確定として出し直されたら、completed に二重に含めない")
  func completedDoesNotDuplicateFinalizedTail() async throws {
    let stub = try StubTranscriptionSession(
      finalSegments: [Self.segment("晴れです。", isFinal: true, start: 1, end: 2)])
    let (audio, input) = AsyncStream.makeStream(of: AudioChunk.self)
    let events = events(stub, audio: audio)
    stub.yield(Self.segment("明日は", isFinal: true))
    stub.yield(Self.segment("はれです", isFinal: false, start: 1, end: 2))
    input.yield(Self.chunk())
    input.finish()

    let collected = await Self.collect(events)

    #expect(collected.last?.kind == .completed("明日は晴れです。"))
  }

  @Test("#48: 末尾の暫定結果が残っていても、確定の失敗・結果の早い終わりは failed のまま")
  func failuresIgnoreUnfinalizedTail() async throws {
    let finalizeFails = try StubTranscriptionSession(
      finalizeError: NSError(domain: NSCocoaErrorDomain, code: 1))
    let (audio, input) = AsyncStream.makeStream(of: AudioChunk.self)
    let failing = events(finalizeFails, audio: audio)
    finalizeFails.yield(Self.segment("あした", isFinal: false))
    input.yield(Self.chunk())
    input.finish()

    #expect(await Self.collect(failing).last?.kind == .failed(.engineFailed))

    let endsEarly = try StubTranscriptionSession()
    let (earlyAudio, earlyInput) = AsyncStream.makeStream(of: AudioChunk.self)
    let early = events(endsEarly, audio: earlyAudio)
    earlyInput.yield(Self.chunk())
    endsEarly.yield(Self.segment("あした", isFinal: false))
    endsEarly.finishResults()

    #expect(await Self.collect(early).map(\.kind) == [.partial("あした"), .failed(.engineFailed)])
    earlyInput.finish()
  }

  @Test("AC-10: 音声が1つもなければ確定を待たずに空の completed で終える")
  func completesEmptyAudio() async throws {
    let stub = try StubTranscriptionSession()
    let collected = await Self.collect(events(stub, audio: AsyncStream { $0.finish() }))

    #expect(collected.map(\.kind) == [.completed("")])
    #expect(!stub.calls.contains(.finalize))
    #expect(stub.calls.contains(.cancel))
  }

  @Test("REC-04: 音声の途中で結果が失敗したら、分類した failed を最後に1回だけ流して止める")
  func failsWhenResultsFail() async throws {
    let stub = try StubTranscriptionSession()
    let (audio, input) = AsyncStream.makeStream(of: AudioChunk.self)
    let events = events(stub, audio: audio)
    input.yield(Self.chunk())
    stub.yield(Self.segment("あ", isFinal: false))
    stub.finishResults(
      throwing: NSError(
        domain: SFSpeechErrorDomain, code: SFSpeechError.Code.insufficientResources.rawValue))

    // 音声は終えていないが、終端イベントで終わる
    let collected = await Self.collect(events)

    #expect(collected.map(\.kind) == [.partial("あ"), .failed(.resourceLimited)])
    #expect(stub.calls.contains(.cancel))
    #expect(!stub.calls.contains(.finalize))
    input.finish()
  }

  @Test("REC-04: 音声の終わりより前に結果が終わったら engineFailed")
  func failsWhenResultsEndEarly() async throws {
    let stub = try StubTranscriptionSession()
    let (audio, input) = AsyncStream.makeStream(of: AudioChunk.self)
    let events = events(stub, audio: audio)
    input.yield(Self.chunk())
    stub.finishResults()

    #expect(await Self.collect(events).map(\.kind) == [.failed(.engineFailed)])
    #expect(stub.calls.contains(.cancel))
    input.finish()
  }

  @Test("REC-04: 途中でサンプリング周波数が変わったら unsupportedAudioFormat")
  func failsOnSampleRateChange() async throws {
    let stub = try StubTranscriptionSession()
    let (audio, input) = AsyncStream.makeStream(of: AudioChunk.self)
    let events = events(stub, audio: audio)
    input.yield(Self.chunk(sampleRate: 16_000))
    input.yield(Self.chunk(sampleRate: 48_000))

    #expect(await Self.collect(events).map(\.kind) == [.failed(.unsupportedAudioFormat)])
    #expect(stub.calls.contains(.cancel))
    input.finish()
  }

  @Test("PERM-03: モデルのロードに失敗したら、分類した failed で終え、解析を始めない")
  func failsWhenPrepareFails() async throws {
    let stub = try StubTranscriptionSession(
      prepareError: NSError(domain: SFSpeechErrorDomain, code: SFSpeechError.Code.noModel.rawValue))

    let collected = await Self.collect(events(stub, audio: AsyncStream { $0.finish() }))

    #expect(collected.map(\.kind) == [.failed(.modelUnavailable)])
    #expect(stub.calls == [.prepare, .cancel])
  }

  @Test("REC-04: 解析の開始・確定に失敗したら failed で終える")
  func failsWhenStartOrFinalizeFails() async throws {
    let error = NSError(domain: NSCocoaErrorDomain, code: 1)
    let startFails = try StubTranscriptionSession(startError: error)
    let finalizeFails = try StubTranscriptionSession(finalizeError: error)
    let audio = {
      AsyncStream<AudioChunk> {
        $0.yield(Self.chunk())
        $0.finish()
      }
    }

    #expect(
      await Self.collect(events(startFails, audio: audio())).map(\.kind) == [.failed(.engineFailed)]
    )
    #expect(
      await Self.collect(events(finalizeFails, audio: audio())).map(\.kind) == [
        .failed(.engineFailed)
      ])
    #expect(startFails.calls == [.prepare, .start, .cancel])
    #expect(finalizeFails.calls.contains(.cancel))
  }

  @Test("PERM-03: 解析器を用意できなければ（モデル未取得など）その失敗で終える")
  func failsWhenSessionUnavailable() async {
    let events = TranscriptionRun.events(
      audio: AsyncStream { $0.finish() }, session: session
    ) { () async -> Result<StubTranscriptionSession, SpeechRecognitionError> in
      .failure(.modelUnavailable)
    }

    #expect(await Self.collect(events).map(\.kind) == [.failed(.modelUnavailable)])
  }

  @Test("REC-04: モデルのロード中に受け手がストリームを破棄したら、解析器を止め、終端イベントを流さない")
  func cancelsDuringPrepare() async throws {
    let stub = try StubTranscriptionSession(blocksPrepare: true)
    let (audio, input) = AsyncStream.makeStream(of: AudioChunk.self)
    let events = events(stub, audio: audio)
    let consumer = Task { await Self.collect(events) }
    try await Self.waitUntil { stub.calls.contains(.prepare) }

    consumer.cancel()

    #expect(await consumer.value.isEmpty)
    try await Self.waitUntil { stub.calls.contains(.cancel) }
    #expect(!stub.calls.contains(.start))
    input.finish()
  }

  @Test("REC-04: 認識中に受け手がストリームを破棄したら、解析器を止めて確定しない")
  func cancelsDuringRecognition() async throws {
    let stub = try StubTranscriptionSession()
    let (audio, input) = AsyncStream.makeStream(of: AudioChunk.self)
    let events = events(stub, audio: audio)
    let consumer = Task { await Self.collect(events) }
    input.yield(Self.chunk())
    try await Self.waitUntil { stub.calls.contains(.start) }

    consumer.cancel()

    #expect(await consumer.value.allSatisfy { !$0.kind.isTerminal })
    try await Self.waitUntil { stub.calls.contains(.cancel) }
    #expect(!stub.calls.contains(.finalize))
    input.finish()
  }

  @Test("#48: 末尾の暫定結果が残っていても、受け手がストリームを破棄したら終端イベントを流さない")
  func cancelsWithUnfinalizedTail() async throws {
    let stub = try StubTranscriptionSession()
    let (audio, input) = AsyncStream.makeStream(of: AudioChunk.self)
    let events = events(stub, audio: audio)
    let consumer = Task { await Self.collect(events) }
    input.yield(Self.chunk())
    try await Self.waitUntil { stub.calls.contains(.start) }
    stub.yield(Self.segment("あした", isFinal: false))

    consumer.cancel()

    #expect(await consumer.value.allSatisfy { !$0.kind.isTerminal })
    try await Self.waitUntil { stub.calls.contains(.cancel) }
    #expect(!stub.calls.contains(.finalize))
    input.finish()
  }

  @Test("REC-06: 終端イベントの後に来たイベントは流さない")
  func emitterDropsEventsAfterTerminal() async {
    let (stream, continuation) = AsyncStream.makeStream(of: RecognitionEvent.self)
    let emitter = RecognitionEventEmitter(session: session, continuation: continuation)

    emitter.emit(.partial("a"))
    emitter.emit(.failed(.engineFailed))
    emitter.emit(.partial("b"))
    emitter.emit(.completed("b"))
    continuation.finish()

    let collected = await Self.collect(stream)
    #expect(collected.map(\.kind) == [.partial("a"), .failed(.engineFailed)])
    #expect(collected.map(\.sequence) == [0, 1])
  }
}
