import Foundation
import Testing
import UtterCore

@testable import UtterSpeech

struct STTWorkerMessageTests {
  private static let session = SessionID()

  private static func roundTrip<T: Codable>(_ value: T) throws -> T {
    // XPC の符号化は Codable 越しに行うため、形式の異なる2つの符号化で往復を確かめる
    let json = try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary
    let plist = try PropertyListDecoder().decode(T.self, from: encoder.encode(value))
    #expect(String(describing: json) == String(describing: plist))
    return plist
  }

  static let requests: [STTWorkerRequest] = [
    .start(session: session, engine: .speechAnalyzer),
    .start(session: session, engine: .whisperKit),
    .start(session: session, engine: .stub),
    .audio(
      session: session, chunk: AudioChunk(samples: [0, 0.5, -1, 1, -0.25], sampleRate: 16_000)),
    .audio(session: session, chunk: AudioChunk(samples: [], sampleRate: 48_000)),
    .finishAudio(session: session),
    .cancel(session: session),
    .updateResources(
      STTWorkerResources(
        policy: try! ModelRetentionPolicy(
          mode: .performance, balancedRetention: .milliseconds(45_500),
          performanceRetentionAllowed: true),
        deviceState: DeviceResourceState(memoryPressure: .warning, isBatteryLow: true))),
  ]

  @Test("AC-10: アプリから Worker へのメッセージは符号化して元に戻せる", arguments: requests)
  func requestRoundTrips(_ request: STTWorkerRequest) throws {
    #expect(try Self.roundTrip(request) == request)
  }

  static let responses: [STTWorkerResponse] =
    [
      RecognitionEvent.Kind.partial("あし"), .confirmed("明日は "), .completed("明日は晴れ"),
    ].enumerated().map { index, kind in
      .event(RecognitionEvent(sessionID: session, sequence: UInt64(index), kind: kind))
    }
    + SpeechRecognitionError.allCases.map {
      .event(RecognitionEvent(sessionID: session, sequence: .max, kind: .failed($0)))
    }

  @Test("AC-10: Worker からアプリへのイベントは符号化して元に戻せる", arguments: responses)
  func responseRoundTrips(_ response: STTWorkerResponse) throws {
    #expect(try Self.roundTrip(response) == response)
  }

  @Test("AC-10: 音声のサンプルはビット列のまま往復する")
  func audioSamplesKeepBitPatterns() throws {
    let samples: [Float] = [
      -0.0, .leastNonzeroMagnitude, .greatestFiniteMagnitude, -.infinity, 0.1,
    ]
    let decoded = try Self.roundTrip(AudioChunk(samples: samples, sampleRate: 16_000))

    #expect(decoded.samples.map(\.bitPattern) == samples.map(\.bitPattern))
    #expect(decoded.sampleRate == 16_000)
  }

  @Test("AC-10: 長さが Float32 の倍数でない音声は復号しない")
  func rejectsTruncatedSamples() throws {
    let json = #"{"samples":"AAAA","sampleRate":16000}"#  // 3 バイト
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(AudioChunk.self, from: Data(json.utf8))
    }
  }

  @Test("6章: 保持時間が 0 以下の保持ポリシーは復号しない")
  func rejectsInvalidRetentionPolicy() throws {
    let json =
      #"{"mode":{"balanced":{}},"balancedRetention":[0,0],"performanceRetentionAllowed":false}"#
    #expect(throws: ModelRetentionPolicyError.nonPositiveRetention) {
      try JSONDecoder().decode(ModelRetentionPolicy.self, from: Data(json.utf8))
    }
  }

  @Test("iAC-10: メッセージの文字列表現に音声・認識テキスト・セッションID を出さない")
  func descriptionsHideContent() {
    let text = "秘密の発話"
    let values: [Any] = [
      STTWorkerRequest.audio(
        session: Self.session, chunk: AudioChunk(samples: [0.123], sampleRate: 16_000)),
      STTWorkerRequest.start(session: Self.session, engine: .whisperKit),
      STTWorkerResponse.event(
        RecognitionEvent(sessionID: Self.session, sequence: 0, kind: .completed(text))),
    ]
    for value in values {
      for rendered in [String(describing: value), String(reflecting: value), dumped(value)] {
        #expect(!rendered.contains(text))
        #expect(!rendered.contains("0.123"))
        #expect(!rendered.contains(Self.session.rawValue.uuidString))
      }
    }
  }

  private func dumped(_ value: Any) -> String {
    var output = ""
    dump(value, to: &output)
    return output
  }
}
