import Testing

@testable import UtterSpeech

struct AudioChunkerTests {
  @Test("REC-05: 揃わない長さで届いたサンプルを、一定の長さのチャンクに区切る")
  func splitsIntoFixedLengthChunks() {
    var chunker = AudioChunker(sampleRate: 1_000, chunkDuration: .milliseconds(10))
    #expect(chunker.samplesPerChunk == 10)

    #expect(chunker.append(Array(repeating: 0.1, count: 7)).isEmpty)
    let chunks = chunker.append(Array(repeating: 0.2, count: 25))

    #expect(
      chunks == [
        AudioChunk(
          samples: Array(repeating: 0.1, count: 7) + Array(repeating: 0.2, count: 3),
          sampleRate: 1_000),
        AudioChunk(samples: Array(repeating: 0.2, count: 10), sampleRate: 1_000),
        AudioChunk(samples: Array(repeating: 0.2, count: 10), sampleRate: 1_000),
      ])
    #expect(chunker.pendingSampleCount == 2)
  }

  @Test("REC-05: 区切りに満たない残りは、録音の終わりに1つのチャンクで流す")
  func flushesRemainder() {
    var chunker = AudioChunker(sampleRate: 1_000, chunkDuration: .milliseconds(10))
    _ = chunker.append(Array(repeating: 0.5, count: 13))

    #expect(
      chunker.flush() == AudioChunk(samples: Array(repeating: 0.5, count: 3), sampleRate: 1_000))
    #expect(chunker.flush() == nil)
    #expect(chunker.pendingSampleCount == 0)
  }

  @Test("4章: 範囲外のサンプルは -1.0〜1.0 に丸め、NaN は無音にする")
  func sanitizesSamples() {
    var chunker = AudioChunker(sampleRate: 1_000, chunkDuration: .milliseconds(4))
    let chunks = chunker.append([1.5, -2, .nan, 0.25])

    #expect(chunks == [AudioChunk(samples: [1, -1, 0, 0.25], sampleRate: 1_000)])
  }

  @Test("4章: 1サンプルに満たない長さなら1サンプルずつ区切る")
  func tinyChunkDurationUsesOneSample() {
    var chunker = AudioChunker(sampleRate: 16_000, chunkDuration: .zero)
    #expect(chunker.samplesPerChunk == 1)
    #expect(chunker.append([0.1, 0.2]).count == 2)
  }

  @Test("4章: 既定は 16kHz で 100ms（1,600 サンプル）ごとに区切る")
  func defaultChunkIsHundredMilliseconds() {
    #expect(AudioChunker(sampleRate: 16_000).samplesPerChunk == 1_600)
  }

  @Test("4章: 複数チャンネルはチャンネルを選ばずに平均してモノラルにする")
  func downmixAveragesChannels() {
    #expect(AudioDownmix.mono([[0.5, 1, -1], [0.5, 0, 1]]) == [0.5, 0.5, 0])
    // 片方のチャンネルにしか音がなくても失わない
    #expect(AudioDownmix.mono([[0, 0], [0.8, -0.8]]) == [0.4, -0.4])
  }

  @Test("4章: モノラルはそのまま、チャンネルがなければ空、長さが違えば短い方に合わせる")
  func downmixEdgeCases() {
    #expect(AudioDownmix.mono([[0.1, 0.2]]) == [0.1, 0.2])
    #expect(AudioDownmix.mono([]).isEmpty)
    #expect(AudioDownmix.mono([[1, 1, 1], [1]]) == [1])
  }
}
