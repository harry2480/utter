import Testing
import UtterCore

@testable import UtterSpeech

struct AudioChunkBufferTests {
  /// 1秒分の音声（サンプリング周波数 10Hz）
  private static func second(_ value: Float = 0) -> AudioChunk {
    AudioChunk(samples: Array(repeating: value, count: 10), sampleRate: 10)
  }

  private static func readAll(_ stream: AsyncStream<AudioChunk>) async -> [AudioChunk] {
    var chunks: [AudioChunk] = []
    for await chunk in stream {
      chunks.append(chunk)
    }
    return chunks
  }

  @Test("REC-05: 上限の既定は330秒で、0 以下は拒否する")
  func limitConfiguration() throws {
    #expect(try AudioChunkBuffer().limit == .seconds(330))
    #expect(throws: AudioChunkBufferError.nonPositiveLimit) {
      try AudioChunkBuffer(limit: .zero)
    }
  }

  @Test("REC-05: 追加した音声を順に読み、録音を終えたら終わる")
  func deliversChunksInOrder() async throws {
    let buffer = try AudioChunkBuffer(limit: .seconds(10))
    let chunks = (1...3).map { Self.second(Float($0) / 10) }

    for chunk in chunks {
      #expect(buffer.append(chunk) == .accepted)
    }
    buffer.finish()

    #expect(await Self.readAll(buffer.stream) == chunks)
    #expect(buffer.closeReason == .finished)
    #expect(buffer.append(Self.second()) == .rejected(.finished))
  }

  @Test("REC-05: 読み手が遅いと、読まれていない音声が上限に達した時点で録音停止扱いにする")
  func slowConsumerReachesLimit() throws {
    let buffer = try AudioChunkBuffer(limit: .seconds(3))

    #expect(buffer.append(Self.second()) == .accepted)
    #expect(buffer.append(Self.second()) == .accepted)
    #expect(buffer.append(Self.second()) == .limitReached)
    #expect(buffer.closeReason == .limitReached)
    #expect(buffer.append(Self.second()) == .rejected(.limitReached))
    #expect(buffer.pendingDuration == .seconds(3))
  }

  @Test("REC-05: 上限に達しても受け入れた音声は捨てずに読み手へ渡す")
  func keepsAudioAfterLimit() async throws {
    let buffer = try AudioChunkBuffer(limit: .seconds(2))
    let chunks = [Self.second(0.1), Self.second(0.2)]
    let overflow = AudioChunk(samples: Array(repeating: 0.3, count: 25), sampleRate: 10)

    #expect(buffer.append(chunks[0]) == .accepted)
    #expect(buffer.append(overflow) == .limitReached)
    #expect(buffer.append(chunks[1]) == .rejected(.limitReached))

    #expect(await Self.readAll(buffer.stream) == [chunks[0], overflow])
  }

  @Test("REC-05: 読み手が読むと読まれていない音声が減り、また受け入れられる（バックプレッシャー）")
  func consumptionRelievesPressure() async throws {
    let buffer = try AudioChunkBuffer(limit: .seconds(3))
    var iterator = buffer.stream.makeAsyncIterator()

    for _ in 0..<2 {
      #expect(buffer.append(Self.second()) == .accepted)
    }
    #expect(buffer.pendingDuration == .seconds(2))
    _ = await iterator.next()
    _ = await iterator.next()
    #expect(buffer.pendingDuration == .zero)

    for _ in 0..<2 {
      #expect(buffer.append(Self.second()) == .accepted)
    }
    #expect(buffer.closeReason == nil)
  }

  @Test("REC-05: 待っている読み手には追加した音声をすぐに渡し、読まれていない音声に数えない", .timeLimit(.minutes(1)))
  func waitingConsumerReceivesDirectly() async throws {
    let buffer = try AudioChunkBuffer(limit: .seconds(1))
    let chunk = Self.second(0.5)
    let reader = Task { await Self.readAll(buffer.stream) }
    while !buffer.hasWaitingConsumer {
      await Task.yield()
    }

    // 上限と同じ長さでも、待っている読み手へ直接渡すため上限に達しない
    #expect(buffer.append(chunk) == .accepted)
    #expect(buffer.pendingDuration == .zero)
    buffer.finish()

    #expect(await reader.value == [chunk])
  }

  @Test("REC-05: 読み手がキャンセルしたら未読の音声を捨て、以後の追加を拒否する")
  func consumerCancellationRejectsAppends() async throws {
    let buffer = try AudioChunkBuffer(limit: .seconds(10))
    for _ in 0..<3 {
      buffer.append(Self.second())
    }
    let reader = Task {
      var count = 0
      for await _ in buffer.stream {
        count += 1
        withUnsafeCurrentTask { $0?.cancel() }
      }
      return count
    }

    #expect(await reader.value == 1)
    #expect(buffer.closeReason == .consumerCancelled)
    #expect(buffer.pendingDuration == .zero)
    #expect(buffer.append(Self.second()) == .rejected(.consumerCancelled))
  }

  @Test("REC-05: 待っている読み手をキャンセルすると、読み手は終わる", .timeLimit(.minutes(1)))
  func cancellingWaitingConsumerEndsIt() async throws {
    let buffer = try AudioChunkBuffer(limit: .seconds(10))
    let reader = Task { await Self.readAll(buffer.stream) }
    while !buffer.hasWaitingConsumer {
      await Task.yield()
    }

    reader.cancel()

    #expect(await reader.value.isEmpty)
    #expect(buffer.closeReason == .consumerCancelled)
  }

  @Test("REC-05: 待っている読み手は録音の終了で終わる", .timeLimit(.minutes(1)))
  func finishEndsWaitingConsumer() async throws {
    let buffer = try AudioChunkBuffer(limit: .seconds(10))
    let reader = Task { await Self.readAll(buffer.stream) }
    while !buffer.hasWaitingConsumer {
      await Task.yield()
    }

    buffer.finish()

    #expect(await reader.value.isEmpty)
    #expect(buffer.closeReason == .finished)
  }

  @Test("REC-05: 読み手が待っている間に来た2つ目の読み手はすぐに終わり、1つ目は影響を受けない", .timeLimit(.minutes(1)))
  func secondConcurrentConsumerEndsImmediately() async throws {
    let buffer = try AudioChunkBuffer(limit: .seconds(10))
    let first = Task { await Self.readAll(buffer.stream) }
    while !buffer.hasWaitingConsumer {
      await Task.yield()
    }

    var second = buffer.stream.makeAsyncIterator()
    #expect(await second.next() == nil)

    let chunk = Self.second(0.7)
    buffer.append(chunk)
    buffer.finish()
    #expect(await first.value == [chunk])
  }

  @Test("REC-05: 読み手が常に少し遅れても、読み済みの音声を保持し続けない")
  func releasesConsumedChunks() async throws {
    let buffer = try AudioChunkBuffer(limit: .seconds(10))
    var iterator = buffer.stream.makeAsyncIterator()
    buffer.append(Self.second())

    for _ in 0..<200 {
      buffer.append(Self.second())
      _ = await iterator.next()
    }

    #expect(buffer.pendingDuration == .seconds(1))
    #expect(buffer.retainedChunkCount < 40)
  }

  @Test("REC-05: 上限到達の後に録音を終えても、閉じた理由は上限到達のまま")
  func closeReasonIsNotOverwritten() throws {
    let buffer = try AudioChunkBuffer(limit: .seconds(1))
    buffer.append(Self.second())
    buffer.finish()

    #expect(buffer.closeReason == .limitReached)
  }

  @Test("REC-05: 音声の長さは整数で求め、足し引きで誤差が積もらない")
  func durationIsExact() {
    let chunk = AudioChunk(samples: Array(repeating: 0, count: 480), sampleRate: 48_000)
    var total: Duration = .zero
    for _ in 0..<100 {
      total += chunk.duration
    }

    #expect(chunk.duration == .milliseconds(10))
    #expect(total == .seconds(1))
    #expect(AudioChunk(samples: [0], sampleRate: 3).duration == .nanoseconds(333_333_333))
  }

  @Test("REC-05: バッファのストリームを Stub の音声認識に渡せる")
  func worksWithRecognizer() async throws {
    let buffer = try AudioChunkBuffer(limit: .seconds(10))
    let recognizer = StubSpeechRecognizer(steps: [.confirmed("はい")], sleep: { _ in })
    let events = recognizer.recognize(buffer.stream, session: SessionID())

    buffer.append(Self.second())
    buffer.finish()
    var kinds: [RecognitionEvent.Kind] = []
    for await event in events {
      kinds.append(event.kind)
    }

    #expect(kinds == [.confirmed("はい"), .completed("はい")])
  }
}
