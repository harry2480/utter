import Foundation
import Testing
import UtterAI
import UtterCore
import UtterPersistence
import UtterSpeech

@testable import UtteriOSKit

@MainActor
struct RecordingSessionModelTests {
  private let directory = TemporaryDirectory()
  private let recorder = FakeRecorder()
  private let copier = RecordingCopier()
  private let createdAt = Date(timeIntervalSince1970: 1_800_000_000)
  private let spoken = "えーと明日の会議は10時からです"

  private var store: SharedResultStore { SharedResultStore(directory: directory.url) }

  private var refined: String {
    LocalBasicRefiner().refine(RefinementRequest(text: spoken, mode: .natural))
  }

  private func model(
    recognizer: any SpeechRecognizer = StubSpeechRecognizer(steps: []),
    storage: SharedResultStorage? = nil,
    policy: RecordingInterruptionPolicy = RecordingInterruptionPolicy(),
    sessionConfiguration: SessionConfiguration = SessionConfiguration(),
    audioBuffer: AudioStreamBuffer = AudioStreamBuffer(),
    clock: TestClock = TestClock(),
    sleep: (@Sendable (Duration) async throws -> Void)? = nil
  ) -> RecordingSessionModel {
    let createdAt = createdAt
    return RecordingSessionModel(
      recorder: recorder, recognizer: recognizer,
      storage: storage ?? SharedResultStorage(store: store, sharing: .appGroup),
      copier: copier, policy: policy, sessionConfiguration: sessionConfiguration,
      audioBuffer: audioBuffer, now: { clock.now },
      // 既定では最大録音時間に達しない（テストが終わるまで待つ）
      sleep: sleep ?? { _ in try await Task.sleep(for: .seconds(3600)) },
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

  @Test("REC-06, iOS-04: 録音を止めると認識・Local Basic の整形を経て結果を保存し、待機に戻る")
  func recordsRecognizesRefinesAndSaves() async throws {
    let model = model(recognizer: speaking)

    await model.toggleRecording()
    #expect(model.phase == .recording)
    #expect(recorder.isRecording)
    recorder.emit(seconds: 1)
    await model.toggleRecording()

    #expect(await waitUntil { model.phase == .idle })
    #expect(!recorder.isRecording)
    let results = try await storedResults()
    #expect(results.map(\.text) == [refined])
    #expect(results.first?.createdAt == createdAt)
    #expect(model.rescueList.items.map(\.state) == [.notInserted(text: refined)])
    #expect(model.failure == nil)
    #expect(model.stopNotice == nil)
  }

  @Test("iOS-PERF-03: マイクを許可されていなければ録音せず、理由を示す")
  func microphoneDenied() async {
    recorder.permits = false
    let model = model()

    await model.startRecording()

    #expect(model.phase == .idle)
    #expect(model.failure == .microphoneDenied)
    #expect(recorder.startCount == 0)
  }

  @Test("REC-05: 録音を開始できなければ録音段階の失敗として示す")
  func recorderFailsToStart() async {
    recorder.failsToStart = true
    let model = model()

    await model.startRecording()

    #expect(model.phase == .error(.recording))
    #expect(model.failure == .recordingUnavailable)
    model.dismissError()
    #expect(model.phase == .idle)
    #expect(model.failure == nil)
  }

  @Test("iOS-PERF-03, REC-05: 着信などの割り込みで止めても、それまでの音声は処理して保存する")
  func interruptionStopsAndProcesses() async throws {
    let model = model(recognizer: speaking)
    await model.startRecording()
    recorder.emit(seconds: 1)

    model.handle(.audioSessionInterruption(began: true))

    #expect(model.phase == .recognizing)
    #expect(!recorder.isRecording)
    #expect(model.stopNotice == .interrupted(.audioInterruption))
    #expect(await waitUntil { model.phase == .idle })
    #expect(try await storedResults().map(\.text) == [refined])
  }

  @Test("iOS-PERF-03: 画面ロック（バックグラウンドへの移動）で録音を止めて処理する")
  func backgroundStopsAndProcesses() async throws {
    let model = model(recognizer: speaking)
    await model.startRecording()
    recorder.emit(seconds: 1)

    model.handle(.appDidEnterBackground)

    #expect(model.stopNotice == .interrupted(.movedToBackground))
    #expect(await waitUntil { model.phase == .idle })
    #expect(try await storedResults().count == 1)
  }

  @Test("iOS-PERF-03: 処理できる音声がないまま割り込まれたら、録音を中止して失敗を示す")
  func interruptionWithoutAudioAborts() async throws {
    let model = model(recognizer: speaking)
    await model.startRecording()

    model.handle(.audioSessionInterruption(began: true))

    #expect(model.phase == .error(.recording))
    #expect(model.failure == .interruptedWithoutAudio(.audioInterruption))
    #expect(!recorder.isRecording)
    #expect(try await storedResults().isEmpty)
  }

  @Test(
    "iOS-PERF-03: 録音を止めない割り込みでは録音を続ける",
    arguments: [
      RecordingSystemSignal.appWillResignActive, .audioSessionInterruption(began: false),
      .audioRouteChange(.newDeviceAvailable), .thermalStateChanged(.serious),
      .lowPowerModeChanged(isEnabled: true),
    ])
  func nonStoppingSignalsContinue(_ signal: RecordingSystemSignal) async {
    let model = model(recognizer: speaking)
    await model.startRecording()
    recorder.emit(seconds: 1)

    model.handle(signal)

    #expect(model.phase == .recording)
    #expect(recorder.isRecording)
    #expect(model.stopNotice == nil)
  }

  @Test(
    "iOS-PERF-03: 入力機器の喪失と熱状態の critical では録音を止める",
    arguments: [
      (
        RecordingSystemSignal.audioRouteChange(.oldDeviceUnavailable),
        RecordingInterruptionCause.inputDeviceLost
      ),
      (.thermalStateChanged(.critical), .thermalState),
    ])
  func routeLossAndThermalStop(
    _ signal: RecordingSystemSignal, _ cause: RecordingInterruptionCause
  ) async {
    let model = model(recognizer: speaking)
    await model.startRecording()
    recorder.emit(seconds: 1)

    model.handle(signal)

    #expect(model.stopNotice == .interrupted(cause))
    #expect(await waitUntil { model.phase == .idle })
  }

  @Test("iOS-PERF-03: 録音を続けられなくなったら、メディアサービスのリセットとして止めて処理する")
  func recorderFailureStopsAndProcesses() async throws {
    let model = model(recognizer: speaking)
    await model.startRecording()
    recorder.emit(seconds: 1)

    recorder.fail()

    #expect(await waitUntil { model.stopNotice == .interrupted(.mediaServicesReset) })
    #expect(await waitUntil { model.phase == .idle })
    #expect(try await storedResults().count == 1)
  }

  @Test("iOS-PERF-03: 録音中以外の割り込みは無視する")
  func ignoresSignalsWhenIdle() {
    let model = model()

    model.handle(.audioSessionInterruption(began: true))

    #expect(model.phase == .idle)
    #expect(model.failure == nil)
  }

  @Test("REC-05: 最大録音時間に達したら自動で止めて処理する")
  func maxDurationStops() async throws {
    let clock = TestClock()
    let model = model(
      recognizer: speaking,
      sessionConfiguration: try SessionConfiguration(maxRecordingDuration: .seconds(10)),
      clock: clock, sleep: { clock.advance(by: $0) })

    await model.startRecording()
    recorder.emit(seconds: 1)

    #expect(await waitUntil { model.stopNotice == .maxDurationReached })
    #expect(!recorder.isRecording)
    #expect(await waitUntil { model.phase == .idle })
    #expect(try await storedResults().count == 1)
  }

  @Test("REC-05: 音声バッファの上限に達したら自動で止めて処理する")
  func bufferLimitStops() async throws {
    // 1秒分（16kHz × 2バイト）
    let model = model(recognizer: speaking, audioBuffer: AudioStreamBuffer(maxBytes: 32_000))
    await model.startRecording()

    recorder.emit(seconds: 2)

    #expect(await waitUntil { model.stopNotice == .bufferLimitReached })
    #expect(!recorder.isRecording)
    #expect(await waitUntil { model.phase == .idle })
    #expect(try await storedResults().count == 1)
  }

  @Test("REC-01: 録音中のキャンセルは結果を保存せず待機に戻る")
  func cancelDiscards() async throws {
    let model = model(recognizer: speaking)
    await model.startRecording()
    recorder.emit(seconds: 1)

    model.cancel()

    #expect(model.phase == .idle)
    #expect(!recorder.isRecording)
    try await Task.sleep(for: .milliseconds(50))
    #expect(model.phase == .idle)
    #expect(try await storedResults().isEmpty)
  }

  @Test("REC-01: 認識中のキャンセルは、後から届いた認識結果を保存しない")
  func cancelWhileRecognizing() async throws {
    let recognizer = ManualSpeechRecognizer()
    let model = model(recognizer: recognizer)
    await model.startRecording()
    recorder.emit(seconds: 1)
    model.stopRecording()
    #expect(model.phase == .recognizing)
    let session = try #require(recognizer.sessions.first)

    model.cancel()
    recognizer.complete(session, text: spoken)

    try await Task.sleep(for: .milliseconds(50))
    #expect(model.phase == .idle)
    #expect(try await storedResults().isEmpty)
  }

  @Test("REC-01, 4章: キャンセルしたセッションの認識結果が、次のセッションの認識中に届いても使わない")
  func staleRecognitionIsDiscarded() async throws {
    let recognizer = ManualSpeechRecognizer()
    let model = model(recognizer: recognizer)
    await model.startRecording()
    recorder.emit(seconds: 1)
    let old = try #require(recognizer.sessions.first)
    model.cancel()

    await model.startRecording()
    recorder.emit(seconds: 1)
    model.stopRecording()
    let current = try #require(recognizer.sessions.first { $0 != old })
    recognizer.complete(old, text: "古い発話")

    try await Task.sleep(for: .milliseconds(50))
    #expect(model.phase == .recognizing)
    #expect(try await storedResults().isEmpty)

    recognizer.complete(current, text: spoken)
    #expect(await waitUntil { model.phase == .idle })
    #expect(try await storedResults().map(\.text) == [refined])
  }

  @Test("REC-06: 許可の確認中にもう一度開始しても、録音は1回だけ始まる")
  func startIsNotReentrant() async {
    recorder.holdsPermission = true
    let model = model(recognizer: speaking)

    let first = Task { await model.startRecording() }
    #expect(await waitUntil { recorder.isAwaitingPermission })
    await model.startRecording()
    recorder.grantPermission()
    await first.value

    #expect(recorder.startCount == 1)
    #expect(model.phase == .recording)
  }

  @Test("iOS-PERF-03: 前のセッションの録音の失敗は、次のセッションを止めない")
  func staleRecorderFailureIsIgnored() async {
    let model = model(recognizer: speaking)
    await model.startRecording()
    model.cancel()
    await model.startRecording()
    recorder.emit(seconds: 1)

    recorder.fail(startedAt: 0)

    try? await Task.sleep(for: .milliseconds(20))
    #expect(model.phase == .recording)
    #expect(recorder.isRecording)
  }

  @Test("iOS-04: STT が未設定なら録音だけを行い、止めた後に未設定であることを示す")
  func unconfiguredRecognizer() async throws {
    let model = model(recognizer: UnconfiguredSpeechRecognizer())
    await model.startRecording()
    recorder.emit(seconds: 1)
    #expect(model.phase == .recording)

    model.stopRecording()

    #expect(await waitUntil { model.phase == .error(.recognition) })
    #expect(model.failure == .recognizerUnavailable)
    #expect(try await storedResults().isEmpty)
  }

  @Test("REC-06: 認識に失敗したら認識段階の失敗として示し、次の録音で閉じる")
  func recognitionFailure() async {
    let model = model(recognizer: StubSpeechRecognizer(steps: [.fail(.engineFailed)]))
    await model.startRecording()

    #expect(await waitUntil { model.phase == .error(.recognition) })
    #expect(model.failure == .recognitionFailed)
    #expect(!recorder.isRecording)

    await model.startRecording()
    #expect(model.phase == .recording)
    #expect(model.failure == nil)
  }

  @Test("REC-06: 認識結果が空なら保存せず、文字にできなかったことを示す")
  func emptyRecognition() async throws {
    let model = model(recognizer: StubSpeechRecognizer(steps: [.confirmed("  ")]))
    await model.startRecording()
    recorder.emit(seconds: 1)

    model.stopRecording()

    #expect(await waitUntil { model.failure == .noSpeech })
    #expect(try await storedResults().isEmpty)
  }

  @Test("iOS-07: 保存できなくても本文を失わず、この画面からコピーできる")
  func saveFailureKeepsText() async throws {
    // 保存先のディレクトリの位置にファイルを置き、ディレクトリを作れないようにする
    try Data().write(to: directory.url)
    let model = model(recognizer: speaking)
    await model.startRecording()
    recorder.emit(seconds: 1)

    model.stopRecording()

    #expect(await waitUntil { model.phase == .error(.insertion) })
    #expect(model.failure == .saveFailed)
    #expect(model.unsavedText == refined)
    await model.copyUnsavedText()
    #expect(copier.copiedTexts == [refined])
    #expect(model.copyNotice == .copied)

    model.dismissError()
    #expect(model.unsavedText == refined)

    // 次の録音を始められなければ、本文はまだ残す
    recorder.permits = false
    await model.startRecording()
    #expect(model.unsavedText == refined)
    recorder.permits = true
    recorder.failsToStart = true
    await model.startRecording()
    #expect(model.unsavedText == refined)
  }

  @Test("iOS-07: 保存した結果を救済画面からコピーすると挿入済みとして扱い、二度目はコピーしない")
  func copySavedResult() async throws {
    let model = model(recognizer: speaking)
    await model.startRecording()
    recorder.emit(seconds: 1)
    model.stopRecording()
    #expect(await waitUntil { model.phase == .idle })
    let sessionID = try #require(model.rescueList.items.first?.sessionID)

    await model.copyResult(sessionID)

    #expect(copier.copiedTexts == [refined])
    #expect(model.copyNotice == .copied)
    // コピーした結果は共有テキストを削除するため、一覧から消える（iOS-IPC-05）
    #expect(model.rescueList.items.isEmpty)

    await model.copyResult(sessionID)
    #expect(copier.copiedTexts == [refined])
    #expect(model.copyNotice == .notCopied)
  }

  @Test("iOS-IPC-05: 起動時の整理で期限切れの結果を削除し、一覧に出さない")
  func prepareResultsRemovesExpired() async throws {
    let expired = SharedResult(
      sessionID: SessionID(), text: "古い本文", createdAt: createdAt.addingTimeInterval(-3600))
    try await store.save(expired, expectedRevision: nil)
    let model = model()

    await model.prepareResults()

    #expect(model.rescueList.items.isEmpty)
    #expect(try await storedResults().isEmpty)
  }

  @Test("iOS-07: 共有の有無を画面に示す")
  func exposesSharing() {
    let storage = SharedResultStorage(
      store: store, sharing: .appLocalOnly(.appGroupNotConfigured))

    #expect(model(storage: storage).sharing == .appLocalOnly(.appGroupNotConfigured))
  }
}
