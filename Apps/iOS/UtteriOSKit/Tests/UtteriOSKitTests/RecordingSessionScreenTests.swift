import Foundation
import Testing
import UtterAI
import UtterCore
import UtterPersistence
import UtterSpeech

@testable import UtteriOSKit

/// 録音セッションのうち、ホーム・録音中・結果の画面に出す値と、結果を消す・録音し直す操作（#201）。
@MainActor
struct RecordingSessionScreenTests {
  private let directory = TemporaryDirectory()
  private let recorder = FakeRecorder()
  private let createdAt = Date(timeIntervalSince1970: 1_800_000_000)
  private let spoken = "えーと明日の会議は10時からです"

  private var store: SharedResultStore { SharedResultStore(directory: directory.url) }

  private func model(
    recognizer: any SpeechRecognizer = StubSpeechRecognizer(steps: []),
    clock: TestClock = TestClock()
  ) -> RecordingSessionModel {
    let createdAt = createdAt
    return RecordingSessionModel(
      recorder: recorder, recognizer: recognizer,
      storage: SharedResultStorage(store: store, sharing: .appGroup),
      copier: RecordingCopier(), now: { clock.now },
      // 最大録音時間に達しない（テストが終わるまで待つ）
      sleep: { _ in try await Task.sleep(for: .seconds(3600)) },
      date: { createdAt })
  }

  private var speaking: StubSpeechRecognizer {
    StubSpeechRecognizer(steps: [.confirmed(spoken)])
  }

  private func storedResults() async throws -> [SharedResult] {
    var results: [SharedResult] = []
    for sessionID in try await store.storedSessionIDs() {
      if let result = try await store.load(sessionID: sessionID) {
        results.append(result)
      }
    }
    return results
  }

  /// 1回録音して結果を保存し、そのセッションIDを返す
  private func recordOnce(_ model: RecordingSessionModel) async throws -> SessionID {
    await model.startRecording()
    recorder.emit(seconds: 1)
    model.stopRecording()
    #expect(await waitUntil { model.phase == .idle && !model.rescueList.items.isEmpty })
    return try #require(model.rescueList.items.first?.sessionID)
  }

  // MARK: 文体

  @Test("TXT-01: 録音を始めたときの文体で整形し、結果に文体と整形先を残す")
  func usesStyleAtStart() async throws {
    let model = model(recognizer: speaking)
    model.refinementMode = .raw

    await model.startRecording()
    // 録音中に文体を変えても、このセッションには使わない
    model.refinementMode = .structured
    #expect(model.sessionRefinementMode == .raw)
    recorder.emit(seconds: 1)
    model.stopRecording()
    #expect(await waitUntil { model.phase == .idle && !model.rescueList.items.isEmpty })

    let raw = LocalBasicRefiner().refine(RefinementRequest(text: spoken, mode: .raw))
    #expect(try await storedResults().map(\.text) == [raw])
    let sessionID = try #require(model.rescueList.items.first?.sessionID)
    let context = try #require(model.resultContexts[sessionID])
    #expect(context.mode == .raw)
    #expect(context.refinement.name == "整形しない（Raw）")
    #expect(!context.refinement.sendsText)
  }

  @Test("AC-06: クラウド整形を結線していない結果は、端末内で整形したことを残す")
  func localResultContext() async throws {
    let model = model(recognizer: speaking)

    let sessionID = try await recordOnce(model)

    let context = try #require(model.resultContexts[sessionID])
    #expect(context.mode == .natural)
    #expect(context.refinement.name == "Local Basic（端末内）")
    #expect(!context.refinement.sendsText)
  }

  // MARK: 録音中の表示

  @Test("REC-05: 録音中は経過時間と最大録音時間を出し、録音中でなければ出さない")
  func showsRecordingProgress() async {
    let clock = TestClock()
    let model = model(clock: clock)
    #expect(model.recordingProgress() == nil)
    #expect(model.maxRecordingDuration == SessionConfiguration.defaultMaxRecordingDuration)

    await model.startRecording()
    clock.advance(by: .seconds(12))

    #expect(model.recordingProgress()?.text == "0:12 / 5:00")
    model.cancel()
    #expect(model.recordingProgress() == nil)
  }

  @Test("#201: 録音中のチャンクの音量だけを波形に足し、録音を止めた後は足さない")
  func levelsWhileRecording() async {
    let model = model()

    await model.startRecording()
    recorder.emit(samples: Array(repeating: 1, count: 1_600))
    #expect(await waitUntil { model.levels.levels == [1] })

    model.stopRecording()
    recorder.emit(samples: Array(repeating: 1, count: 1_600))
    // 止めた後に届いたチャンクの音量は足さない
    try? await Task.sleep(for: .milliseconds(50))
    #expect(model.levels.levels == [1])
  }

  @Test("2.2節: STT の途中経過を、確定した部分と聞き取り中の部分に分けて持つ")
  func interimTranscript() async {
    let model = model(recognizer: StubSpeechRecognizer(steps: [.confirmed("明日の"), .partial("会議")]))

    await model.startRecording()

    #expect(await waitUntil { model.transcript.provisionalText == "会議" })
    #expect(model.transcript.confirmedText == "明日の")
    model.cancel()
  }

  @Test("2.2節, #201: 新しい録音を始めたら、前の途中の文字と波形を残さない")
  func startResetsTranscriptAndLevels() async {
    let model = model(recognizer: StubSpeechRecognizer(steps: [.partial("前の発話")]))
    await model.startRecording()
    recorder.emit(samples: Array(repeating: 1, count: 1_600))
    #expect(await waitUntil { !model.transcript.provisionalText.isEmpty })
    #expect(await waitUntil { !model.levels.levels.isEmpty })
    model.cancel()

    await model.startRecording()

    #expect(model.transcript.provisionalText.isEmpty)
    #expect(model.levels.levels.isEmpty)
    model.cancel()
  }

  // MARK: この文章を消す・録音し直す

  @Test("iOS-IPC-01: 「この文章を消す」で結果を消し、キーボードからもコピーからも使えなくする")
  func discardsResult() async throws {
    let model = model(recognizer: speaking)
    let sessionID = try await recordOnce(model)

    #expect(await model.discardResult(sessionID))

    #expect(model.discardNotice == .discarded)
    #expect(model.rescueList.items.isEmpty)
    #expect(try await storedResults().isEmpty)
    #expect(model.resultContexts[sessionID] == nil)
  }

  @Test("iOS-IPC-03: キーボードが挿入中の結果は消さない")
  func discardSkipsInsertingResult() async throws {
    let sessionID = SessionID()
    var result = SharedResult(sessionID: sessionID, text: "本文", createdAt: createdAt)
    try result.beginInsertion(for: sessionID, at: createdAt)
    try await store.save(result, expectedRevision: nil)
    let model = model()

    #expect(!(await model.discardResult(sessionID)))

    #expect(model.discardNotice == .inserting)
    #expect(try await storedResults().count == 1)
  }

  @Test("iOS-07: 「録音し直す」で結果を消してから新しい録音を始める")
  func recordsAgain() async throws {
    let model = model(recognizer: speaking)
    let sessionID = try await recordOnce(model)

    await model.recordAgain(sessionID)

    #expect(model.phase == .recording)
    #expect(recorder.startCount == 2)
    #expect(try await storedResults().isEmpty)
    model.cancel()
  }

  @Test("iOS-IPC-03: 結果を消せなければ録音し直さない")
  func recordAgainNeedsDiscard() async throws {
    let sessionID = SessionID()
    var result = SharedResult(sessionID: sessionID, text: "本文", createdAt: createdAt)
    try result.beginInsertion(for: sessionID, at: createdAt)
    try await store.save(result, expectedRevision: nil)
    let model = model()

    await model.recordAgain(sessionID)

    #expect(model.phase == .idle)
    #expect(recorder.startCount == 0)
    #expect(model.discardNotice == .inserting)
  }

  @Test("REC-06: 録音中は録音し直さない（結果も消さない）")
  func recordAgainWhileRecordingDoesNothing() async throws {
    let model = model(recognizer: speaking)
    let sessionID = try await recordOnce(model)
    await model.startRecording()

    await model.recordAgain(sessionID)

    #expect(recorder.startCount == 2)
    #expect(try await storedResults().count == 1)
    model.cancel()
  }
}
