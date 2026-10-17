import Testing

@testable import UtterSpeech

struct AudioCaptureTests {
  /// `count` 個のサンプルを持つチャンク（PCM16 換算で `count * 2` バイト）
  private func chunk(_ count: Int, value: Float = 0.5) -> AudioChunk {
    AudioChunk(samples: Array(repeating: value, count: count), sampleRate: 16_000)
  }

  @Test("REC-05: 上限に収まるチャンクはすべて受け入れ、バイト数を数える")
  func acceptsWithinLimit() {
    var capture = AudioCapture(buffer: AudioStreamBuffer(maxBytes: 100))

    let first = capture.append(chunk(10))
    let second = capture.append(chunk(20))

    #expect(first.result == .accepted)
    #expect(second.result == .accepted)
    #expect(second.kept == chunk(20))
    #expect(capture.byteCount == 60)
    #expect(capture.stopReason == nil)
  }

  @Test("REC-05: 上限を超えるチャンクは収まる先頭だけを残し、録音を停止扱いにする")
  func keepsFittingPrefixAndStopsAtLimit() {
    var capture = AudioCapture(buffer: AudioStreamBuffer(maxBytes: 100))
    _ = capture.append(chunk(40))

    let overflow = capture.append(chunk(30, value: 0.25))

    #expect(overflow.result == .limitReached(keptSampleCount: 10))
    #expect(overflow.kept == chunk(10, value: 0.25))
    #expect(capture.byteCount == 100)
    #expect(capture.stopReason == .limitReached)
  }

  @Test("REC-05: ちょうど上限に達したチャンクは全体を残して停止する")
  func stopsWhenExactlyReachingLimit() {
    var capture = AudioCapture(buffer: AudioStreamBuffer(maxBytes: 100))

    let exact = capture.append(chunk(50))

    #expect(exact.result == .limitReached(keptSampleCount: 50))
    #expect(exact.kept == chunk(50))
    #expect(capture.stopReason == .limitReached)
  }

  @Test("REC-05: 停止後のチャンクは受け入れず、停止理由を返す")
  func rejectsAfterStop() {
    var capture = AudioCapture(buffer: AudioStreamBuffer(maxBytes: 100))
    _ = capture.append(chunk(50))

    let after = capture.append(chunk(1))

    #expect(after.result == .stopped(.limitReached))
    #expect(after.kept == nil)
    #expect(capture.byteCount == 100)
  }

  @Test("REC-05: 停止理由は最初の停止のまま変わらない")
  func keepsFirstStopReason() {
    var capture = AudioCapture(buffer: AudioStreamBuffer(maxBytes: 100))

    let first = capture.stop(.finished)
    let second = capture.stop(.cancelled)

    #expect(first)
    #expect(!second)
    #expect(capture.stopReason == .finished)
  }
}

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
