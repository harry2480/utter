import Testing

@testable import UtterSpeech

struct BoundedAudioStreamTests {
  private func chunk(_ count: Int, value: Float = 0.5) -> AudioChunk {
    AudioChunk(samples: Array(repeating: value, count: count), sampleRate: 16_000)
  }

  private func collect(_ chunks: AsyncStream<AudioChunk>) async -> [AudioChunk] {
    var received: [AudioChunk] = []
    for await chunk in chunks {
      received.append(chunk)
    }
    return received
  }

  @Test("REC-05: 消費側が遅くても、上限内のチャンクを落とさず順に届ける（バックプレッシャー）")
  func slowConsumerReceivesAllChunksInOrder() async {
    let (stream, chunks) = BoundedAudioStream.make(buffer: AudioStreamBuffer(maxBytes: 1_000))
    let sent = (1...10).map { chunk(10, value: Float($0) / 10) }

    // 消費側が読み始める前に、録音側がすべて流す。yield は待たずに戻る
    for chunk in sent {
      #expect(stream.yield(chunk) == .accepted)
    }
    stream.finish()

    #expect(await collect(chunks) == sent)
    #expect(stream.stopReason == .finished)
  }

  @Test("REC-05: 上限に達したら収まる分まで流してストリームを終え、上限到達を区別できる")
  func finishesStreamAtLimitKeepingAudio() async {
    let (stream, chunks) = BoundedAudioStream.make(buffer: AudioStreamBuffer(maxBytes: 100))

    #expect(stream.yield(chunk(30)) == .accepted)
    #expect(stream.yield(chunk(30, value: 0.25)) == .limitReached(keptSampleCount: 20))
    #expect(stream.yield(chunk(5)) == .stopped(.limitReached))

    #expect(await collect(chunks) == [chunk(30), chunk(20, value: 0.25)])
    #expect(stream.stopReason == .limitReached)
    #expect(stream.byteCount == 100)
  }

  @Test("REC-05: 録音を終えた後のチャンクは流さない")
  func rejectsAfterFinish() async {
    let (stream, chunks) = BoundedAudioStream.make(buffer: AudioStreamBuffer(maxBytes: 100))
    stream.yield(chunk(10))
    stream.finish()

    #expect(stream.yield(chunk(10)) == .stopped(.finished))
    #expect(await collect(chunks) == [chunk(10)])
  }

  @Test("REC-05: 受け手のタスクがキャンセルされたら、録音を止めた扱いにする")
  func consumerCancellationStopsCapture() async {
    let (stream, chunks) = BoundedAudioStream.make(buffer: AudioStreamBuffer(maxBytes: 100))
    stream.yield(chunk(10))

    // キャンセル済みのタスクが next() に入った時点で、ストリームの終了処理が呼ばれる
    let consumer = Task {
      for await _ in chunks {}
    }
    consumer.cancel()
    await consumer.value

    #expect(stream.stopReason == .cancelled)
    #expect(stream.yield(chunk(10)) == .stopped(.cancelled))
    #expect(stream.byteCount == 20)
  }

  @Test("REC-05: 上限が奇数バイトで1サンプルも収まらないときは、何も流さずに終える")
  func finishesWithoutKeepingWhenNoSampleFits() async {
    let (stream, chunks) = BoundedAudioStream.make(buffer: AudioStreamBuffer(maxBytes: 101))

    #expect(stream.yield(chunk(50)) == .accepted)
    #expect(stream.yield(chunk(1)) == .limitReached(keptSampleCount: 0))

    #expect(await collect(chunks) == [chunk(50)])
    #expect(stream.stopReason == .limitReached)
    #expect(stream.byteCount == 100)
  }

  @Test("REC-05: 空のチャンクは流さず、上限の判定にも影響しない")
  func doesNotEnqueueEmptyChunks() async {
    let (stream, chunks) = BoundedAudioStream.make(buffer: AudioStreamBuffer(maxBytes: 100))

    for _ in 0..<1_000 {
      #expect(stream.yield(chunk(0)) == .accepted)
    }
    stream.yield(chunk(10))
    stream.finish()

    #expect(await collect(chunks) == [chunk(10)])
    #expect(stream.byteCount == 20)
  }
}
