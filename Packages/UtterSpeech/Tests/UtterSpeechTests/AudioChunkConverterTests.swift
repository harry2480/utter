import AVFoundation
import Testing

@testable import UtterSpeech

struct AudioChunkConverterTests {
  private static func format(
    _ commonFormat: AVAudioCommonFormat, sampleRate: Double
  ) throws -> AVAudioFormat {
    try #require(
      AVAudioFormat(
        commonFormat: commonFormat, sampleRate: sampleRate, channels: 1, interleaved: false))
  }

  private static func sine(count: Int, sampleRate: Int, offset: Int = 0) -> AudioChunk {
    AudioChunk(
      samples: (0..<count).map {
        0.5 * sin(2 * Float.pi * 440 * Float($0 + offset) / Float(sampleRate))
      },
      sampleRate: sampleRate)
  }

  @Test("REC-05: 出力と同じ形式の音声は、サンプルをそのまま渡す")
  func passesThroughSameFormat() throws {
    let converter = AudioChunkConverter(
      outputFormat: try Self.format(.pcmFormatFloat32, sampleRate: 16_000))
    let chunk = AudioChunk(samples: [0, 0.25, -0.5, 1], sampleRate: 16_000)

    let buffer = try #require(try converter.convert(chunk))

    #expect(buffer.frameLength == 4)
    let channel = try #require(buffer.floatChannelData?[0])
    #expect((0..<4).map { channel[$0] } == chunk.samples)
    #expect(try converter.flush() == nil)
  }

  @Test("REC-05: サンプリング周波数と形式を変換し、flush で末尾まで渡す")
  func resamplesToAnalyzerFormat() throws {
    let output = try Self.format(.pcmFormatInt16, sampleRate: 16_000)
    let converter = AudioChunkConverter(outputFormat: output)
    var frames: AVAudioFrameCount = 0
    var peak: Int16 = 0

    // 48kHz の1秒を 100ms ずつ
    for index in 0..<10 {
      let chunk = Self.sine(count: 4_800, sampleRate: 48_000, offset: index * 4_800)
      if let buffer = try converter.convert(chunk) {
        #expect(buffer.format == output)
        frames += buffer.frameLength
        let channel = try #require(buffer.int16ChannelData?[0])
        peak = max(peak, (0..<Int(buffer.frameLength)).map { abs(channel[$0]) }.max() ?? 0)
      }
    }
    if let rest = try converter.flush() {
      frames += rest.frameLength
    }

    #expect(abs(Int(frames) - 16_000) <= 2)
    // 振幅 0.5 の正弦波が無音や飽和にならずに届いている
    #expect(Int(peak) > Int(Int16.max) / 3 && Int(peak) < Int(Int16.max) * 2 / 3)
  }

  @Test("REC-05: 空のチャンクは何も渡さない")
  func ignoresEmptyChunk() throws {
    let converter = AudioChunkConverter(
      outputFormat: try Self.format(.pcmFormatInt16, sampleRate: 16_000))

    #expect(try converter.convert(AudioChunk(samples: [], sampleRate: 48_000)) == nil)
  }

  @Test("REC-05: 途中でサンプリング周波数が変わったら unsupportedAudioFormat")
  func rejectsSampleRateChange() throws {
    let converter = AudioChunkConverter(
      outputFormat: try Self.format(.pcmFormatInt16, sampleRate: 16_000))
    _ = try converter.convert(Self.sine(count: 480, sampleRate: 48_000))

    #expect(throws: SpeechRecognitionError.unsupportedAudioFormat) {
      try converter.convert(Self.sine(count: 441, sampleRate: 44_100))
    }
  }

  @Test("REC-05: サンプリング周波数が 0 以下なら unsupportedAudioFormat", arguments: [0, -16_000])
  func rejectsInvalidSampleRate(_ sampleRate: Int) throws {
    let converter = AudioChunkConverter(
      outputFormat: try Self.format(.pcmFormatInt16, sampleRate: 16_000))

    #expect(throws: SpeechRecognitionError.unsupportedAudioFormat) {
      try converter.convert(AudioChunk(samples: [0, 0.1], sampleRate: sampleRate))
    }
  }
}
