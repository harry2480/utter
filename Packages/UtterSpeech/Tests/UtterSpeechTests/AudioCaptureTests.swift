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
