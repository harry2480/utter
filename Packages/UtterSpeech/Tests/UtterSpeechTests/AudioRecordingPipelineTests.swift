import Synchronization
import Testing
import UtterCore

@testable import UtterSpeech

struct AudioRecordingPipelineTests {
  private func collect<Element>(_ stream: AsyncStream<Element>) async -> [Element] {
    var received: [Element] = []
    for await element in stream {
      received.append(element)
    }
    return received
  }

  /// 1kHz・10ms（10サンプル）ごとに区切る
  private func make(
    maxBytes: Int = 1_000, onEnd: @escaping @Sendable (AudioRecordingEnd) -> Void = { _ in }
  ) -> (pipeline: AudioRecordingPipeline, recording: AudioRecording) {
    AudioRecordingPipeline.make(
      buffer: AudioStreamBuffer(maxBytes: maxBytes), sampleRate: 1_000,
      chunkDuration: .milliseconds(10), onEnd: onEnd)
  }

  @Test("REC-05: 録音を終えたら、区切りに満たない残りも流してから終える")
  func finishFlushesRemainder() async {
    let (pipeline, recording) = make()
    pipeline.append(Array(repeating: 0.5, count: 15))

    #expect(pipeline.end(.finished))

    let chunks = await collect(recording.chunks)
    #expect(chunks.map(\.samples.count) == [10, 5])
    #expect(
      await collect(recording.ends) == [
        AudioRecordingEnd(reason: .finished, capturedDuration: .milliseconds(15))
      ])
  }

  @Test("REC-05: 上限に達したら収まる分まで流して自動で止め、上限到達を区別できる")
  func stopsAtLimit() async {
    let ended = Mutex<[AudioRecordingEnd]>([])
    // 25サンプル（PCM16 で 50 バイト）まで
    let (pipeline, recording) = make(maxBytes: 50) { end in ended.withLock { $0.append(end) } }

    pipeline.append(Array(repeating: 0.5, count: 40))
    pipeline.append(Array(repeating: 0.5, count: 10))

    #expect(pipeline.isEnded)
    #expect(await collect(recording.chunks).map(\.samples.count) == [10, 10, 5])
    let expected = AudioRecordingEnd(reason: .limitReached, capturedDuration: .milliseconds(25))
    #expect(await collect(recording.ends) == [expected])
    #expect(ended.withLock { $0 } == [expected])
  }

  @Test("REC-04: 割り込みで止まったときも、それまでの音声を流して理由を知らせる")
  func interruptionKeepsAudio() async {
    let (pipeline, recording) = make()
    pipeline.append(Array(repeating: 0.5, count: 12))

    pipeline.end(.interrupted(.audioRouteChanged(.inputDeviceLost)))

    #expect(await collect(recording.chunks).map(\.samples.count) == [10, 2])
    #expect(
      await collect(recording.ends).map(\.reason) == [
        .interrupted(.audioRouteChanged(.inputDeviceLost))
      ])
  }

  @Test("REC-04: 終わりは1回だけ知らせ、終わった後のサンプルと停止は受け付けない")
  func endsOnlyOnce() async {
    let count = Mutex(0)
    let (pipeline, recording) = make { _ in count.withLock { $0 += 1 } }
    pipeline.append(Array(repeating: 0.5, count: 10))

    #expect(pipeline.end(.finished))
    #expect(!pipeline.end(.interrupted(.audioInterruptionBegan)))
    pipeline.append(Array(repeating: 0.5, count: 10))

    #expect(count.withLock { $0 } == 1)
    #expect(await collect(recording.chunks).map(\.samples.count) == [10])
    #expect(await collect(recording.ends).map(\.reason) == [.finished])
  }

  @Test("REC-04: 音声の受け手がストリームを破棄したら、録音を止めて知らせる")
  func receiverCancellationEnds() async {
    let (pipeline, recording) = make()
    let task = Task { [chunks = recording.chunks] in
      for await _ in chunks {}
    }
    task.cancel()
    await task.value

    pipeline.append(Array(repeating: 0.5, count: 10))

    #expect(pipeline.isEnded)
    #expect(await collect(recording.ends).map(\.reason) == [.cancelled])
  }

  @Test("REC-04: 終わりを知らせた先から停止を呼んでも止まらない")
  func reentrantEndFromCallback() async {
    let holder = Mutex<AudioRecordingPipeline?>(nil)
    let (pipeline, recording) = make(maxBytes: 20) { _ in
      // 録音アダプターは onEnd から停止の処理を呼ぶ
      _ = holder.withLock { $0 }?.end(.finished)
    }
    holder.withLock { $0 = pipeline }

    pipeline.append(Array(repeating: 0.5, count: 20))

    #expect(await collect(recording.ends).map(\.reason) == [.limitReached])
  }

  @Test("REC-04: 受け手が読むのをやめてストリームを手放したら、録音を止めて知らせる")
  func receiverDroppingStreamEnds() async {
    let pipeline: AudioRecordingPipeline
    let ends: AsyncStream<AudioRecordingEnd>
    do {
      // 受け手は1つ読んだらやめ、このスコープを出るとストリームを手放す
      let (made, recording) = make()
      pipeline = made
      ends = recording.ends
      made.append(Array(repeating: 0.5, count: 10))
      for await _ in recording.chunks { break }
    }

    pipeline.append(Array(repeating: 0.5, count: 10))

    #expect(pipeline.isEnded)
    #expect(await collect(ends).map(\.reason) == [.cancelled])
  }

  @Test("REC-05: 終えるときの残りが上限に収まらなければ、収まる分を流して上限到達として知らせる")
  func flushBeyondLimitReportsLimit() async {
    // 10サンプル（PCM16 で 21 バイト。端数の1バイトには収まらない）まで
    let (pipeline, recording) = make(maxBytes: 21)
    pipeline.append(Array(repeating: 0.5, count: 8))

    pipeline.append(Array(repeating: 0.5, count: 4))
    pipeline.end(.finished)

    #expect(await collect(recording.chunks).map(\.samples.count) == [10])
    #expect(await collect(recording.ends).map(\.reason) == [.limitReached])
  }

  @Test("REC-05: 終えるときの残りがちょうど上限に収まれば、呼び出し側の理由で終える")
  func flushExactlyAtLimitKeepsReason() async {
    let (pipeline, recording) = make(maxBytes: 30)
    pipeline.append(Array(repeating: 0.5, count: 15))

    pipeline.end(.interrupted(.audioInterruptionBegan))

    #expect(await collect(recording.chunks).map(\.samples.count) == [10, 5])
    #expect(await collect(recording.ends).map(\.reason) == [.interrupted(.audioInterruptionBegan)])
  }

  @Test("REC-04: 受け手が読むのをやめたら、次のチャンクを待たずに録音を止めて知らせる")
  func receiverCancellationEndsWithoutFurtherAudio() async {
    let (pipeline, recording) = make()
    // 区切りに満たない音声だけがある（次のチャンクはまだ流れない）
    pipeline.append(Array(repeating: 0.5, count: 3))
    let task = Task { [chunks = recording.chunks] in
      for await _ in chunks {}
    }
    task.cancel()
    await task.value

    #expect(pipeline.isEnded)
    #expect(await collect(recording.ends).map(\.reason) == [.cancelled])
  }
}
