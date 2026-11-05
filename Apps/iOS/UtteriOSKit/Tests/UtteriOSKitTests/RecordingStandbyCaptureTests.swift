import Foundation
import Testing
import UtterAI
import UtterCore
import UtterPersistence
import UtterSpeech

@testable import UtteriOSKit

/// 待機セッションの録音を、本体アプリの録音セッションで行う（iOS-04, iOS-06, #247）。
/// 録音・音声認識は差し替え、共有結果は一時ディレクトリに保存する。
@MainActor
struct RecordingStandbyCaptureTests {
  private let directory = TemporaryDirectory()
  private let recorder = FakeRecorder()
  private let spoken = "えーと明日の会議は10時からです"

  private var store: SharedResultStore { SharedResultStore(directory: directory.url) }

  private var refined: String {
    LocalBasicRefiner().refine(RefinementRequest(text: spoken, mode: .natural))
  }

  private func model(
    recognizer: any SpeechRecognizer = StubSpeechRecognizer(steps: [])
  ) -> RecordingSessionModel {
    RecordingSessionModel(
      recorder: recorder, recognizer: recognizer,
      storage: SharedResultStorage(store: store, sharing: .appGroup),
      copier: RecordingCopier(),
      // 最大録音時間には達しない（テストが終わるまで待つ）
      sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
  }

  private var speaking: StubSpeechRecognizer {
    StubSpeechRecognizer(steps: [.confirmed(spoken)])
  }

  @Test("iOS-04: キーボードが作ったIDで録音を始め、止めるとそのIDで共有結果を保存する")
  func savesWithKeyboardSessionID() async throws {
    let model = model(recognizer: speaking)
    let capture = RecordingStandbyCapture(model: model)
    let sessionID = SessionID()

    capture.beginCapture(sessionID)
    #expect(await waitUntil { recorder.isRecording })
    #expect(model.activeSessionID == sessionID)
    recorder.emit(seconds: 1)

    #expect(await capture.finishCapture(sessionID) == nil)
    #expect(!recorder.isRecording)
    let result = try await store.load(sessionID: sessionID)
    #expect(result?.text == refined)
  }

  @Test("iOS-04: 認識できる発話がなければ noSpeech を返し、結果を保存しない")
  func noSpeechReported() async throws {
    let model = model()
    let capture = RecordingStandbyCapture(model: model)
    let sessionID = SessionID()

    capture.beginCapture(sessionID)
    #expect(await waitUntil { recorder.isRecording })

    #expect(await capture.finishCapture(sessionID) == .noSpeech)
    #expect(try await store.storedSessionIDs().isEmpty)
  }

  @Test("iOS-06: 捨てると録音を止め、結果を保存しない")
  func abandonDiscardsCapture() async throws {
    let model = model(recognizer: speaking)
    let capture = RecordingStandbyCapture(model: model)
    let sessionID = SessionID()

    capture.beginCapture(sessionID)
    #expect(await waitUntil { recorder.isRecording })
    recorder.emit(seconds: 1)

    capture.abandonCapture(sessionID)
    #expect(await waitUntil { model.phase == .idle && !recorder.isRecording })
    #expect(await model.outcome(of: sessionID) == .cancelled)
    #expect(try await store.storedSessionIDs().isEmpty)
  }

  @Test("iOS-04: マイクの許可の確認中に停止の合図が届いても落とさず、録音を始めてから止める")
  func finishWhileStartingIsKept() async throws {
    recorder.holdsPermission = true
    let model = model(recognizer: speaking)
    let capture = RecordingStandbyCapture(model: model)
    let sessionID = SessionID()

    capture.beginCapture(sessionID)
    #expect(await waitUntil { recorder.isAwaitingPermission })
    let finishing = Task { await capture.finishCapture(sessionID) }

    recorder.grantPermission()
    #expect(await finishing.value == nil)
    #expect(!recorder.isRecording)
    #expect(try await store.load(sessionID: sessionID)?.text == refined)
  }

  @Test("iOS-04: 別のセッションの開始で前の録音を捨てるときは、捨て終えてから新しい録音を始める")
  func supersedingSessionStartsAfterAbandon() async throws {
    // 前の録音の開始が、マイクの許可の確認で止まっている間に交代の合図が届く
    recorder.holdsPermission = true
    let model = model(recognizer: speaking)
    let capture = RecordingStandbyCapture(model: model)
    let previous = SessionID()
    let next = SessionID()

    capture.beginCapture(previous)
    #expect(await waitUntil { recorder.isAwaitingPermission })
    // StandbySessionMachine は、前の録音を捨ててから新しい録音を始めるよう続けて求める
    capture.abandonCapture(previous)
    capture.beginCapture(next)
    recorder.holdsPermission = false
    recorder.grantPermission()

    #expect(await waitUntil { model.activeSessionID == next && recorder.isRecording })
    recorder.emit(seconds: 1)
    #expect(await capture.finishCapture(next) == nil)
    #expect(try await store.load(sessionID: next)?.text == refined)
    #expect(try await store.load(sessionID: previous) == nil)
  }

  @Test("iOS-06: 開始の順番を待つ間に取り消されたセッションは、録音を始めない")
  func abandonedBeforeStartNeverStarts() async {
    // 最初の録音の開始がマイクの許可の確認で止まっている間に、交代と取り消しの合図が続けて届く
    recorder.holdsPermission = true
    let model = model(recognizer: speaking)
    let capture = RecordingStandbyCapture(model: model)
    let first = SessionID()
    let queued = SessionID()
    let last = SessionID()

    capture.beginCapture(first)
    #expect(await waitUntil { recorder.isAwaitingPermission })
    capture.abandonCapture(first)
    capture.beginCapture(queued)
    capture.abandonCapture(queued)
    recorder.holdsPermission = false
    recorder.grantPermission()
    // 操作は届いた順に行うため、最後の開始が済めば、それより前の操作もすべて済んでいる
    capture.beginCapture(last)

    #expect(await waitUntil { model.activeSessionID == last && recorder.isRecording })
    // 録音を始めたのは最初と最後だけで、取り消されたセッションは始めていない
    #expect(recorder.startCount == 2)
    model.cancel()
  }

  @Test("iOS-04: 渡したIDのセッションが進行中でなければ止めない（本体アプリで始めた録音を止めない）")
  func doesNotStopAnotherSession() async {
    let model = model(recognizer: speaking)
    let capture = RecordingStandbyCapture(model: model)

    await model.startRecording()
    #expect(model.phase == .recording)

    #expect(await capture.finishCapture(SessionID()) == .processingFailed)
    #expect(model.phase == .recording)
    #expect(recorder.isRecording)
    model.cancel()
  }

  @Test("iOS-04: 終わる前から待っても、終わった後に待っても、同じ終わり方を返す")
  func outcomeBeforeAndAfterCompletion() async {
    let model = model(recognizer: speaking)
    let sessionID = SessionID()

    await model.startRecording(sessionID: sessionID)
    recorder.emit(seconds: 1)
    let waiting = Task { await model.outcome(of: sessionID) }
    model.stopRecording()

    #expect(await waiting.value == .saved)
    #expect(await model.outcome(of: sessionID) == .saved)
  }
}
