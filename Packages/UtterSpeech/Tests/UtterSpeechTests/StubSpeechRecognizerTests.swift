import Synchronization
import Testing
import UtterCore

@testable import UtterSpeech

struct StubSpeechRecognizerTests {
  private let session = SessionID()

  private static func silence() -> AsyncStream<AudioChunk> {
    AsyncStream { $0.finish() }
  }

  private func collect(_ recognizer: StubSpeechRecognizer) async -> [RecognitionEvent] {
    var events: [RecognitionEvent] = []
    for await event in recognizer.recognize(Self.silence(), session: session) {
      events.append(event)
    }
    return events
  }

  @Test("REC-06: 固定のイベント列をセッションID と順序番号つきで流す")
  func emitsScriptedEvents() async {
    let recognizer = StubSpeechRecognizer(
      steps: [.partial("あし"), .confirmed("明日は"), .partial("はれ"), .completed("明日は晴れ")],
      sleep: { _ in })

    let events = await collect(recognizer)

    #expect(
      events.map(\.kind) == [
        .partial("あし"), .confirmed("明日は"), .partial("はれ"), .completed("明日は晴れ"),
      ])
    #expect(events.map(\.sequence) == [0, 1, 2, 3])
    #expect(events.allSatisfy { $0.sessionID == session })
  }

  @Test("REC-06: 完了を含まない手順は確定テキストを連結して完了する")
  func completesWithConfirmedText() async {
    let recognizer = StubSpeechRecognizer(
      steps: [.confirmed("明日は"), .confirmed("晴れ")], sleep: { _ in })

    let events = await collect(recognizer)

    #expect(events.last?.kind == .completed("明日は晴れ"))
    #expect(events.count == 3)
  }

  @Test("REC-06: 失敗を注入すると failed で終わり、以降の手順は流さない", arguments: SpeechRecognitionError.allCases)
  func injectsFailure(_ error: SpeechRecognitionError) async {
    let recognizer = StubSpeechRecognizer(
      steps: [.partial("あ"), .fail(error), .completed("流さない")], sleep: { _ in })

    let events = await collect(recognizer)

    #expect(events.map(\.kind) == [.partial("あ"), .failed(error)])
  }

  @Test("REC-06: 完了の後の手順は流さない")
  func stopsAfterCompleted() async {
    let recognizer = StubSpeechRecognizer(steps: [.completed("a"), .partial("b")], sleep: { _ in })

    #expect(await collect(recognizer).map(\.kind) == [.completed("a")])
  }

  @Test("REC-06: 遅延は注入した sleep で待ち、実時間を待たない")
  func delaysWithInjectedSleep() async {
    let recorded = Mutex<[Duration]>([])
    let recognizer = StubSpeechRecognizer(
      steps: [.delay(.seconds(5)), .partial("a"), .delay(.milliseconds(300)), .completed("a")],
      sleep: { duration in recorded.withLock { $0.append(duration) } })

    let events = await collect(recognizer)

    #expect(recorded.withLock { $0 } == [.seconds(5), .milliseconds(300)])
    #expect(events.count == 2)
  }

  @Test("REC-06: 受け手がストリームを破棄すると認識を止める")
  func stopsWhenConsumerCancels() async {
    let recognizer = StubSpeechRecognizer(
      steps: [.partial("a"), .delay(.seconds(60)), .partial("b"), .completed("ab")])

    var received: [RecognitionEvent] = []
    for await event in recognizer.recognize(Self.silence(), session: session) {
      received.append(event)
      break
    }

    #expect(received.map(\.kind) == [.partial("a")])
  }

  @Test("REC-06: 待機中にキャンセルされたら完了を流さない")
  func cancellationDuringDelayEndsWithoutCompletion() async {
    let recognizer = StubSpeechRecognizer(
      steps: [.delay(.seconds(1)), .partial("a")],
      sleep: { _ in throw CancellationError() })

    #expect(await collect(recognizer).isEmpty)
  }
}
