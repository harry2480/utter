import Testing
import UtterCore
import UtterSpeech

@testable import UtteriOSKit

struct UnconfiguredSpeechRecognizerTests {
  @Test("4章: 音声のストリームが終わるまで読み、終わったら未設定として失敗を1回だけ流す")
  func failsAfterAudioEnds() async {
    let (audio, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
    let session = SessionID()
    let events = UnconfiguredSpeechRecognizer().recognize(audio, session: session)
    continuation.yield(AudioChunk(samples: [0, 0], sampleRate: 16_000))
    continuation.finish()

    var received: [RecognitionEvent] = []
    for await event in events {
      received.append(event)
    }

    #expect(
      received == [
        RecognitionEvent(sessionID: session, sequence: 0, kind: .failed(.modelUnavailable))
      ])
  }
}
