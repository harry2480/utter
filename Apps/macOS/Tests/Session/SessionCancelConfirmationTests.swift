import Testing
import UtterCore

/// 確認の表示の代わり。出した回数・閉じた回数を数え、答えをテストから渡す
@MainActor
final class StubCancelConfirmationPresenter: SessionCancelConfirmationPresenting {
  private(set) var presentCount = 0
  private(set) var dismissCount = 0
  private var onAnswer: (@MainActor (Bool) -> Void)?

  func present(onAnswer: @escaping @MainActor (Bool) -> Void) {
    presentCount += 1
    self.onAnswer = onAnswer
  }

  func dismiss() {
    dismissCount += 1
    onAnswer = nil
  }

  /// 利用者が答えた
  func answer(_ confirmed: Bool) {
    let onAnswer = self.onAnswer
    self.onAnswer = nil
    onAnswer?(confirmed)
  }
}

/// 処理中にもう一度ショートカットを押したときのキャンセルの確認（REC-06, REC-01, #199）
@MainActor
struct SessionCancelConfirmationTests {
  /// テストから変える、セッションの状態とキャンセルの回数
  @MainActor
  final class FakeSession {
    var phase: SessionPhase = .recognizing
    var id: SessionID? = SessionID()
    private(set) var cancelCount = 0

    func cancel() {
      cancelCount += 1
      phase = .idle
      id = nil
    }
  }

  private let presenter: StubCancelConfirmationPresenter
  private let session: FakeSession

  init() {
    presenter = StubCancelConfirmationPresenter()
    session = FakeSession()
  }

  private func makeConfirmation() -> SessionCancelConfirmation {
    let session = session
    return SessionCancelConfirmation(
      presenter: presenter, phase: { session.phase }, session: { session.id },
      cancel: { session.cancel() })
  }

  @Test(
    "REC-06: 認識中・整形中に確認を出し、キャンセルを選んだらキャンセルする",
    arguments: [SessionPhase.recognizing, .refining])
  func cancelsWhenConfirmed(phase: SessionPhase) {
    session.phase = phase
    let confirmation = makeConfirmation()

    confirmation.request()
    #expect(presenter.presentCount == 1)
    #expect(confirmation.isPresenting)

    presenter.answer(true)
    #expect(session.cancelCount == 1)
    #expect(!confirmation.isPresenting)
  }

  @Test("REC-06: 続けるを選んだらキャンセルしない")
  func keepsProcessingWhenDeclined() {
    let confirmation = makeConfirmation()
    confirmation.request()
    presenter.answer(false)
    #expect(session.cancelCount == 0)
    #expect(!confirmation.isPresenting)
  }

  @Test(
    "REC-01, REC-06: 認識中・整形中でなければ確認を出さない",
    arguments: [SessionPhase.idle, .recording, .inserting, .error(.recognition)])
  func doesNotPresentOutsideProcessing(phase: SessionPhase) {
    session.phase = phase
    let confirmation = makeConfirmation()
    confirmation.request()
    #expect(presenter.presentCount == 0)
  }

  @Test("REC-06: 確認を出している間にもう一度押されても出し直さない")
  func doesNotPresentTwice() {
    let confirmation = makeConfirmation()
    confirmation.request()
    confirmation.request()
    #expect(presenter.presentCount == 1)
  }

  @Test("REC-01: 確認の間に挿入が始まったら閉じ、後から答えてもキャンセルしない")
  func dismissesWhenProcessingEnds() {
    let confirmation = makeConfirmation()
    confirmation.request()

    session.phase = .refining
    confirmation.sessionPhaseDidChange()
    #expect(presenter.dismissCount == 0)

    session.phase = .inserting
    confirmation.sessionPhaseDidChange()
    #expect(presenter.dismissCount == 1)
    #expect(!confirmation.isPresenting)

    presenter.answer(true)
    #expect(session.cancelCount == 0)
  }

  @Test("REC-06: 確認を出したセッションが終わり、次のセッションが処理中になっても、そのセッションはキャンセルしない")
  func doesNotCancelAnotherSession() {
    let confirmation = makeConfirmation()
    confirmation.request()
    // 答える前に、通知を待たずに別のセッションへ移った
    session.id = SessionID()
    presenter.answer(true)
    #expect(session.cancelCount == 0)
  }
}
