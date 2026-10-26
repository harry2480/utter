import Foundation
import Testing
import UtterAI
import UtterCore
import UtterPersistence
import UtterSpeech

/// アプリの異常終了後の起動時の復旧（7章, AC-10）。保存先は一時ディレクトリの実際のストア、認識・確認・プレビューは Stub。
@MainActor
struct LaunchAudioRecoveryTests {
  let directory = TemporaryAudioDirectory()
  let preview = StubRecoveryPreview()
  let gate = StubRecoveryGate()

  private func queue() throws -> TemporaryAudioStoreQueue {
    TemporaryAudioStoreQueue(store: try directory.store())
  }

  /// 前回の起動で残った一時音声を置く
  @discardableResult
  private func leaveAudio(
    in queue: TemporaryAudioStoreQueue, samples: Int = 1_600
  ) throws -> SessionID {
    var audio = try RecordedAudio(sampleRate: 16_000)
    try audio.append(
      AudioChunk(samples: [Float](repeating: 0.25, count: samples), sampleRate: 16_000))
    let session = SessionID()
    try queue.store.save(audio.encoded(), for: session)
    return session
  }

  private func recovery(
    _ queue: TemporaryAudioStoreQueue, recognizer: (any SpeechRecognizer)?,
    prompt: StubAudioRecoveryPrompt, mode: RefinementMode = .raw,
    gate: StubRecoveryGate? = nil
  ) -> LaunchAudioRecovery {
    LaunchAudioRecovery(
      queue: queue, recognizer: recognizer, refinementMode: mode, prompt: prompt, preview: preview,
      gate: gate ?? self.gate, sleep: { _ in })
  }

  @Test("AC-10: 復旧候補がなければ尋ねない")
  func noCandidates() async throws {
    let prompt = StubAudioRecoveryPrompt(answer: true)
    let recognizer = RecordingSpeechRecognizer(steps: [.confirmed("使わない")])

    let outcome = await recovery(try queue(), recognizer: recognizer, prompt: prompt).start().value

    #expect(outcome == .noCandidates)
    #expect(prompt.askedCounts.isEmpty)
    #expect(recognizer.sessions.isEmpty)
    #expect(preview.shown.isEmpty)
  }

  @Test("AC-10: 復旧を選んだら、同じセッションID で認識し直してプレビューに出し（自動挿入しない）、音声を削除する")
  func recoversToPreview() async throws {
    let queue = try queue()
    let session = try leaveAudio(in: queue)
    let prompt = StubAudioRecoveryPrompt(answer: true)
    let recognizer = RecordingSpeechRecognizer(steps: [.confirmed("復旧した発話")])

    let outcome = await recovery(queue, recognizer: recognizer, prompt: prompt).start().value

    #expect(outcome == .attempted(previewed: 1, unrecovered: 0))
    #expect(prompt.askedCounts == [1])
    #expect(recognizer.sessions == [session])
    #expect(preview.shown.map(\.text) == ["復旧した発話"])
    #expect(preview.shown.map(\.cause) == [.recoveredAfterRestart])
    #expect(prompt.reportedUnrecovered.isEmpty)
    await queue.drain()
    #expect(try queue.store.list().isEmpty)
  }

  @Test("AC-10, AI-03: 復旧した文字列はローカルで整形してからプレビューに出す")
  func refinesRecoveredText() async throws {
    let queue = try queue()
    try leaveAudio(in: queue)
    let text = "えーと、明日は晴れです"

    _ = await recovery(
      queue, recognizer: RecordingSpeechRecognizer(steps: [.confirmed(text)]),
      prompt: StubAudioRecoveryPrompt(answer: true), mode: .natural
    ).start().value

    let expected = LocalBasicRefiner().refine(
      RefinementRequest(
        text: text, mode: .natural, style: AppStyleResolver().style(forBundleID: nil)))
    #expect(preview.shown.map(\.text) == [expected])
  }

  @Test("AC-10: 断ったら、認識せずに候補の音声をすべて削除する")
  func declineRemovesAudio() async throws {
    let queue = try queue()
    try leaveAudio(in: queue)
    try leaveAudio(in: queue)
    let prompt = StubAudioRecoveryPrompt(answer: false)
    let recognizer = RecordingSpeechRecognizer(steps: [.confirmed("使わない")])

    let outcome = await recovery(queue, recognizer: recognizer, prompt: prompt).start().value

    #expect(outcome == .declined(count: 2))
    #expect(prompt.askedCounts == [2])
    #expect(recognizer.sessions.isEmpty)
    #expect(preview.shown.isEmpty)
    #expect(try queue.store.list().isEmpty)
  }

  @Test("AC-10: 認識し直せなかったら音声を残し、件数を知らせる（次回の起動時にもう一度尋ねる）")
  func keepsAudioWhenRecognitionFails() async throws {
    let queue = try queue()
    let session = try leaveAudio(in: queue)
    let prompt = StubAudioRecoveryPrompt(answer: true)

    let outcome = await recovery(
      queue, recognizer: RecordingSpeechRecognizer(steps: [.fail(.engineFailed)]), prompt: prompt
    ).start().value

    #expect(outcome == .attempted(previewed: 0, unrecovered: 1))
    #expect(prompt.reportedUnrecovered == [1])
    #expect(preview.shown.isEmpty)
    #expect(try queue.store.list().map(\.sessionID) == [session])
  }

  @Test("11章, AC-10: 音声認識が使えなければ尋ねず、音声は保持期限まで残す")
  func keepsAudioWithoutRecognizer() async throws {
    let queue = try queue()
    try leaveAudio(in: queue)
    let prompt = StubAudioRecoveryPrompt(answer: true)

    let outcome = await recovery(queue, recognizer: nil, prompt: prompt).start().value

    #expect(outcome == .recognizerUnavailable(count: 1))
    #expect(prompt.askedCounts.isEmpty)
    #expect(try queue.store.list().count == 1)
  }

  @Test("AC-10: 保持期限を過ぎた音声は尋ねずに削除する")
  func removesExpiredAudio() async throws {
    let saved = Date(timeIntervalSince1970: 1_800_000_000)
    let old = TemporaryAudioStoreQueue(store: try directory.store(now: saved))
    try leaveAudio(in: old)
    let later = TemporaryAudioStoreQueue(
      store: try directory.store(now: saved.addingTimeInterval(24 * 60 * 60 + 1)))
    let prompt = StubAudioRecoveryPrompt(answer: true)

    let outcome = await recovery(
      later, recognizer: RecordingSpeechRecognizer(steps: []), prompt: prompt
    ).start().value

    #expect(outcome == .noCandidates)
    #expect(prompt.askedCounts.isEmpty)
    #expect(try later.store.list().isEmpty)
  }

  @Test("AC-10: 起動後に保存したセッションの音声は、復旧候補に含めない")
  func excludesAudioSavedAfterLaunch() async throws {
    let queue = try queue()
    let prompt = StubAudioRecoveryPrompt(answer: true)
    let retention = TemporaryAudioRetention(queue: queue)

    let task = recovery(queue, recognizer: RecordingSpeechRecognizer(steps: []), prompt: prompt)
      .start()
    // 起動直後に録音したセッション（整理と候補の取得の後に保存される）
    let session = SessionID()
    retention.begin(session)
    retention.append(AudioChunk(samples: [0.1, 0.2], sampleRate: 16_000), to: session)
    retention.finishRecording(session)

    #expect(await task.value == .noCandidates)
    await queue.drain()
    #expect(try queue.store.list().map(\.sessionID) == [session])
  }

  @Test("AC-10, REC-06: 録音・処理中のセッションが終わるのを待ってから尋ね、復旧を終えるまで新しいセッションを止める")
  func waitsForIdleSession() async throws {
    let queue = try queue()
    try leaveAudio(in: queue)
    let gate = StubRecoveryGate(busyAnswers: 3)
    let prompt = StubAudioRecoveryPrompt(answer: true)
    prompt.onAsk = { gate.wasSuspendedWhen.append(gate.isSuspended) }

    let outcome = await recovery(
      queue, recognizer: RecordingSpeechRecognizer(steps: [.confirmed("発話")]), prompt: prompt,
      gate: gate
    ).start().value

    #expect(outcome == .attempted(previewed: 1, unrecovered: 0))
    #expect(gate.suspendAttempts == 4)
    #expect(gate.wasSuspendedWhen == [true])
    #expect(!gate.isSuspended)
  }

  @Test("AC-10: 断ったときも、新しいセッションの停止を解く")
  func resumesAfterDecline() async throws {
    let queue = try queue()
    try leaveAudio(in: queue)

    _ = await recovery(
      queue, recognizer: RecordingSpeechRecognizer(steps: []),
      prompt: StubAudioRecoveryPrompt(answer: false)
    )
    .start().value

    #expect(gate.suspendAttempts == 1)
    #expect(!gate.isSuspended)
  }
}
