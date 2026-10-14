import Testing
import UtterCore

@testable import UtterSpeech

struct RecognitionEventFilterTests {
  private let current = SessionID()
  private let other = SessionID()

  private func event(
    _ session: SessionID, _ sequence: UInt64, _ kind: RecognitionEvent.Kind = .partial("a")
  ) -> RecognitionEvent {
    RecognitionEvent(sessionID: session, sequence: sequence, kind: kind)
  }

  @Test("REC-06: 現在のセッションのイベントを順序どおりに受け付ける")
  func acceptsInOrderEvents() {
    var filter = RecognitionEventFilter()
    filter.begin(current)

    #expect(filter.accept(event(current, 0)) == nil)
    #expect(filter.accept(event(current, 1)) == nil)
    #expect(filter.accept(event(current, 3)) == nil)
    #expect(filter.lastSequence == 3)
  }

  @Test("REC-06: 開始前・別のセッションのイベントは破棄する")
  func discardsOtherSessions() {
    var filter = RecognitionEventFilter()
    #expect(filter.accept(event(current, 0)) == .inactiveSession)

    filter.begin(current)
    #expect(filter.accept(event(other, 0)) == .inactiveSession)
  }

  @Test("REC-06: 受け取った順序番号以前のイベントは破棄する", arguments: [UInt64(0), 1, 2])
  func discardsOutOfOrder(_ sequence: UInt64) {
    var filter = RecognitionEventFilter()
    filter.begin(current)
    _ = filter.accept(event(current, 2))

    #expect(filter.accept(event(current, sequence)) == .outOfOrder)
    #expect(filter.lastSequence == 2)
  }

  @Test("REC-01: キャンセル後に届いたイベントは破棄する")
  func discardsAfterCancel() {
    var filter = RecognitionEventFilter()
    filter.begin(current)
    _ = filter.accept(event(current, 0))

    let cancelled = filter.cancel(current)

    #expect(cancelled)

    #expect(filter.accept(event(current, 1, .completed("遅延"))) == .inactiveSession)
    #expect(filter.activeSession == nil)
  }

  @Test("REC-01: 前のセッションの ID で遅れて届いたキャンセルは、新しいセッションを止めない")
  func staleCancelDoesNotStopNewSession() {
    var filter = RecognitionEventFilter()
    filter.begin(other)
    filter.begin(current)

    let cancelled = filter.cancel(other)

    #expect(!cancelled)
    #expect(filter.activeSession == current)
    #expect(filter.accept(event(current, 0)) == nil)
  }

  @Test(
    "REC-06: completed / failed を受け付けるとセッションを終え、以降を破棄する",
    arguments: [RecognitionEvent.Kind.completed("a"), .failed(.engineFailed)])
  func terminalEventEndsSession(_ kind: RecognitionEvent.Kind) {
    var filter = RecognitionEventFilter()
    filter.begin(current)

    #expect(filter.accept(event(current, 0, kind)) == nil)
    #expect(filter.accept(event(current, 1)) == .inactiveSession)
  }

  @Test("REC-06: 新しいセッションを始めると前のセッションのイベントを破棄し、順序番号を数え直す")
  func beginResetsSession() {
    var filter = RecognitionEventFilter()
    filter.begin(other)
    _ = filter.accept(event(other, 5))

    filter.begin(current)

    #expect(filter.accept(event(other, 6)) == .inactiveSession)
    #expect(filter.accept(event(current, 0)) == nil)
  }

  @Test("REC-06: partial / confirmed は最後のイベントではない")
  func terminalKinds() {
    #expect(!RecognitionEvent.Kind.partial("a").isTerminal)
    #expect(!RecognitionEvent.Kind.confirmed("a").isTerminal)
    #expect(RecognitionEvent.Kind.completed("a").isTerminal)
    #expect(RecognitionEvent.Kind.failed(.modelUnavailable).isTerminal)
  }
}
