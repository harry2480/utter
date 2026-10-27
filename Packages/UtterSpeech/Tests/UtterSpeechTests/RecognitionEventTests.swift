import Testing
import UtterCore

@testable import UtterSpeech

struct RecognitionEventTests {
  @Test(
    "REC-06: イベントの文字列表現に認識テキストを含めない",
    arguments: [
      RecognitionEvent.Kind.partial("秘密の発話"), .confirmed("秘密の発話"), .completed("秘密の発話"),
    ])
  func redactsText(_ kind: RecognitionEvent.Kind) {
    let event = RecognitionEvent(sessionID: SessionID(), sequence: 3, kind: kind)
    let outputs = [
      String(describing: event),
      String(reflecting: event),
      String(describing: Mirror(reflecting: event).children.map(\.value)),
      String(describing: kind),
      String(reflecting: kind),
      String(describing: Mirror(reflecting: kind).children.map(\.value)),
    ]

    for output in outputs {
      #expect(!output.contains("秘密の発話"))
    }
    #expect(String(describing: event).contains("length: 5"))
    #expect(String(describing: event).contains("sequence: 3"))
  }

  @Test("REC-06: 失敗のイベントは種類を出す")
  func describesFailure() {
    #expect(
      String(describing: RecognitionEvent.Kind.failed(.engineFailed)) == "failed(engineFailed)")
  }

  @Test("REC-05: 音声の文字列表現にサンプルを含めず、長さを求められる")
  func audioChunk() {
    let chunk = AudioChunk(samples: [0.25, -0.5, 0.125, 0.75], sampleRate: 2)
    let outputs = [
      String(describing: chunk), String(reflecting: chunk),
      String(describing: Mirror(reflecting: chunk).children.map(\.value)),
    ]

    for output in outputs {
      #expect(!output.contains("0.25"))
    }
    #expect(String(describing: chunk) == "AudioChunk(sampleCount: 4, sampleRate: 2)")
    #expect(chunk.duration == .seconds(2))
    #expect(AudioChunk(samples: [0], sampleRate: 0).duration == .zero)
  }

  @Test("REC-06: 失敗の種類を区別する")
  func distinguishesErrors() {
    #expect(
      Set(SpeechRecognitionError.allCases) == [
        .modelUnavailable, .unsupportedAudioFormat, .engineFailed, .resourceLimited,
        .consentNotGranted, .sensitiveInput, .audioLimitExceeded, .budgetExceeded, .timeout,
        .authenticationExpired, .quotaExceeded, .networkUnavailable, .invalidResponse,
      ])
  }
}
