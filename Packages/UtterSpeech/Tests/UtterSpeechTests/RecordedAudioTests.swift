import Foundation
import Testing
import UtterCore

@testable import UtterSpeech

struct RecordedAudioTests {
  private func recorded(_ chunks: [AudioChunk], sampleRate: Int = 4) throws -> RecordedAudio {
    var audio = try RecordedAudio(sampleRate: sampleRate)
    for chunk in chunks {
      try audio.append(chunk)
    }
    return audio
  }

  @Test("AC-10: 保存したバイト列から、PCM16 の精度で同じ音声に戻せる")
  func roundTrips() throws {
    let samples: [Float] = [0, 0.5, -0.5, 1, -1, 0.123]
    let audio = try recorded([AudioChunk(samples: samples, sampleRate: 4)])

    let restored = try RecordedAudio(decoding: audio.encoded())

    #expect(restored == audio)
    #expect(restored.sampleRate == 4)
    #expect(restored.duration == .seconds(1.5))
    let replayed = restored.chunks(chunkDuration: .seconds(10)).flatMap(\.samples)
    #expect(replayed.count == samples.count)
    for (original, decoded) in zip(samples, replayed) {
      #expect(abs(original - decoded) <= 1 / Float(Int16.max))
    }
  }

  @Test("AC-10: 識別子・版・周波数の後に PCM16 のサンプルを置く")
  func encodesHeaderAndSamples() throws {
    let audio = try recorded(
      [AudioChunk(samples: [1, -1], sampleRate: 16_000)], sampleRate: 16_000)

    let bytes = [UInt8](audio.encoded())

    #expect(Array(bytes[0..<4]) == Array("UTAU".utf8))
    #expect(Array(bytes[4..<8]) == [1, 0, 0, 0])
    #expect(Array(bytes[8..<12]) == [0x80, 0x3E, 0, 0])
    #expect(Array(bytes[12...]) == [0xFF, 0x7F, 0x01, 0x80])
  }

  @Test("REC-05: 範囲外のサンプルは端に丸め、NaN は無音にする")
  func clampsAndSilencesInvalidSamples() throws {
    let audio = try recorded([
      AudioChunk(samples: [2, -3, .nan, .infinity, -.infinity], sampleRate: 4)
    ])

    let replayed = audio.chunks(chunkDuration: .seconds(10)).flatMap(\.samples)

    #expect(replayed == [1, -1, 0, 1, -1])
  }

  @Test("AC-10: 録音と違うサンプリング周波数のチャンクは足さない")
  func rejectsMismatchedSampleRate() throws {
    var audio = try recorded([AudioChunk(samples: [0.5], sampleRate: 4)])

    #expect(throws: RecordedAudioError.sampleRateMismatch) {
      try audio.append(AudioChunk(samples: [0.5, 0.5], sampleRate: 8))
    }
    #expect(audio.sampleCount == 1)
  }

  @Test(
    "AC-10: サンプリング周波数が 0 以下、または保存形式で表せないなら作らない",
    arguments: [0, -16_000, Int(UInt32.max) + 1])
  func rejectsInvalidSampleRate(_ sampleRate: Int) {
    #expect(throws: RecordedAudioError.invalidSampleRate) {
      try RecordedAudio(sampleRate: sampleRate)
    }
  }

  @Test(
    "AC-10: 形式の識別子・版が違うバイト列は読まない",
    arguments: [
      Data(),
      Data("UTAU".utf8),
      Data("WAVE".utf8 + [1, 0, 0, 0, 4, 0, 0, 0]),
      Data("UTAU".utf8 + [2, 0, 0, 0, 4, 0, 0, 0]),
    ])
  func rejectsUnsupportedFormat(_ data: Data) {
    #expect(throws: RecordedAudioError.unsupportedFormat) {
      try RecordedAudio(decoding: data)
    }
  }

  @Test(
    "AC-10: 長さやサンプリング周波数が壊れたバイト列は読まない",
    arguments: [
      Data("UTAU".utf8 + [1, 0, 0, 0, 0, 0, 0, 0]),
      Data("UTAU".utf8 + [1, 0, 0, 0, 4, 0, 0, 0, 0xFF]),
    ])
  func rejectsCorruptedData(_ data: Data) {
    #expect(throws: RecordedAudioError.corrupted) {
      try RecordedAudio(decoding: data)
    }
  }

  @Test("AC-10: 保存形式の最大の周波数と最小のサンプルも範囲内で読める")
  func decodesExtremes() throws {
    let restored = try RecordedAudio(
      decoding: Data("UTAU".utf8 + [1, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x80]))

    #expect(restored.sampleRate == Int(UInt32.max))
    #expect(restored.chunks().flatMap(\.samples) == [-1])
  }

  @Test("AC-10: 空の録音も保存して戻し、音声認識を最後まで進められる")
  func replaysEmptyRecording() async throws {
    let restored = try RecordedAudio(decoding: RecordedAudio(sampleRate: 16_000).encoded())
    let recognizer = StubSpeechRecognizer(steps: [])
    var last: RecognitionEvent.Kind?
    for await event in recognizer.recognize(restored.stream(), session: SessionID()) {
      last = event.kind
    }

    #expect(restored.sampleCount == 0)
    #expect(last == .completed(""))
  }

  @Test("AC-10: 先頭が 0 でないバイト列の一部からも戻せる")
  func decodesDataSlice() throws {
    let audio = try recorded([AudioChunk(samples: [0.5, -0.25], sampleRate: 4)])
    let padded = Data([0xAA, 0xBB]) + audio.encoded()

    let restored = try RecordedAudio(decoding: padded.dropFirst(2))

    #expect(restored == audio)
  }

  @Test("AC-10: 流し直すチャンクは指定の長さで区切り、最後のチャンクは短くなる")
  func splitsIntoChunks() throws {
    let audio = try recorded([
      AudioChunk(samples: [0, 0, 0], sampleRate: 4), AudioChunk(samples: [0, 0], sampleRate: 4),
    ])

    #expect(audio.chunks(chunkDuration: .milliseconds(500)).map(\.samples.count) == [2, 2, 1])
    #expect(audio.chunks(chunkDuration: .zero).map(\.samples.count) == [1, 1, 1, 1, 1])
    #expect(audio.chunks(chunkDuration: .milliseconds(-100)).count == 5)
    #expect(audio.chunks(chunkDuration: .seconds(Int64.max)).map(\.samples.count) == [5])
    #expect(audio.chunks().allSatisfy { $0.sampleRate == 4 })
    #expect(try RecordedAudio(sampleRate: 4).chunks().isEmpty)
  }

  @Test("AC-10: 区切りのサンプル数は浮動小数点の誤差で少なくならない")
  func computesChunkSizeExactly() throws {
    let audio = try recorded(
      [AudioChunk(samples: Array(repeating: 0, count: 60), sampleRate: 100)], sampleRate: 100)

    #expect(audio.chunks(chunkDuration: .milliseconds(570)).map(\.samples.count) == [57, 3])
    #expect(audio.chunks(chunkDuration: .milliseconds(290)).first?.samples.count == 29)
  }

  @Test("AC-10: ストリームはすべてのチャンクを流して終わり、音声認識が最後まで進む")
  func replaysIntoRecognizer() async throws {
    let audio = try recorded([AudioChunk(samples: [0.1, 0.2, 0.3, 0.4, 0.5], sampleRate: 4)])
    var replayed: [AudioChunk] = []
    for await chunk in audio.stream(chunkDuration: .milliseconds(500)) {
      replayed.append(chunk)
    }
    #expect(replayed == audio.chunks(chunkDuration: .milliseconds(500)))

    let recognizer = StubSpeechRecognizer(steps: [.confirmed("明日の"), .confirmed("会議")])
    var last: RecognitionEvent.Kind?
    for await event in recognizer.recognize(audio.stream(), session: SessionID()) {
      last = event.kind
    }
    #expect(last == .completed("明日の会議"))
  }

  @Test("REC-06: 文字列表現にサンプルを含めない")
  func redactsSamples() throws {
    let audio = try recorded([AudioChunk(samples: [0.25, -0.5], sampleRate: 4)])
    let outputs = [
      String(describing: audio), String(reflecting: audio),
      String(describing: Mirror(reflecting: audio).children.map(\.value)),
    ]

    for output in outputs {
      #expect(!output.contains("0.25"))
      #expect(!output.contains("8192"))
    }
    #expect(String(describing: audio) == "RecordedAudio(sampleCount: 2, sampleRate: 4)")
  }
}
