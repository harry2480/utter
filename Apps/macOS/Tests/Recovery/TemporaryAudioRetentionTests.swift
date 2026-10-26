import Foundation
import Testing
import UtterCore
import UtterPersistence
import UtterSpeech

/// セッションの録音音声の一時保存（7章, AC-10）。保存先は一時ディレクトリの実際のストアを使う。
@MainActor
struct TemporaryAudioRetentionTests {
  let directory = TemporaryAudioDirectory()

  private func make() throws -> (TemporaryAudioRetention, TemporaryAudioStoreQueue) {
    let queue = TemporaryAudioStoreQueue(store: try directory.store())
    return (TemporaryAudioRetention(queue: queue), queue)
  }

  private func chunk(_ count: Int, rate: Int = 16_000) -> AudioChunk {
    AudioChunk(samples: [Float](repeating: 0.25, count: count), sampleRate: rate)
  }

  @Test("AC-10: 録音中はメモリに溜めるだけで、録音が止まったら一時音声を保存する")
  func savesWhenRecordingFinishes() async throws {
    let (retention, queue) = try make()
    let session = SessionID()

    retention.begin(session)
    retention.append(chunk(1_600), to: session)
    retention.append(chunk(800), to: session)
    await queue.drain()
    #expect(try queue.store.list().isEmpty)
    #expect(retention.recordedAudio(for: session)?.sampleCount == 2_400)
    #expect(retention.recordedAudio(for: SessionID()) == nil)

    retention.finishRecording(session)
    await queue.drain()

    let records = try queue.store.list()
    #expect(records.map(\.sessionID) == [session])
    let saved = try RecordedAudio(decoding: queue.store.load(try #require(records.first)))
    #expect(saved == retention.recordedAudio(for: session))
  }

  @Test("AC-10: 成功・失敗のどちらで終わっても、保存した一時音声とメモリ上の音声を削除する", arguments: [true, false])
  func removesOnEnd(_ completed: Bool) async throws {
    let (retention, queue) = try make()
    let session = SessionID()

    retention.begin(session)
    retention.append(chunk(1_600), to: session)
    retention.finishRecording(session)
    retention.end(session, completed: completed)
    await queue.drain()

    #expect(try queue.store.list().isEmpty)
    #expect(retention.recordedAudio(for: session) == nil)
  }

  @Test("AC-10, REC-01: 録音中にキャンセルしたら保存せず、後から届いたチャンク・録音の終わりも保存しない")
  func cancelBeforeRecordingFinishes() async throws {
    let (retention, queue) = try make()
    let session = SessionID()

    retention.begin(session)
    retention.append(chunk(1_600), to: session)
    retention.end(session, completed: false)
    retention.append(chunk(1_600), to: session)
    retention.finishRecording(session)
    await queue.drain()

    #expect(try queue.store.list().isEmpty)
    #expect(retention.recordedAudio(for: session) == nil)
  }

  @Test("AC-10: 音声がないまま録音が止まったら保存しない")
  func doesNotSaveEmptyRecording() async throws {
    let (retention, queue) = try make()
    let session = SessionID()

    retention.begin(session)
    retention.finishRecording(session)
    await queue.drain()

    #expect(try queue.store.list().isEmpty)
  }

  @Test("AC-10: 途中でサンプリング周波数が変わったら、その録音は再処理にも保存にも使わない")
  func dropsInconsistentSampleRate() async throws {
    let (retention, queue) = try make()
    let session = SessionID()

    retention.begin(session)
    retention.append(chunk(1_600), to: session)
    retention.append(chunk(1_600, rate: 48_000), to: session)
    retention.append(chunk(1_600), to: session)
    retention.finishRecording(session)
    await queue.drain()

    #expect(retention.recordedAudio(for: session) == nil)
    #expect(try queue.store.list().isEmpty)
  }

  @Test("AC-10: 次のセッションは前のセッションの音声を持ち越さない")
  func nextSessionStartsEmpty() async throws {
    let (retention, queue) = try make()
    let first = SessionID()
    let second = SessionID()

    retention.begin(first)
    retention.append(chunk(1_600), to: first)
    retention.finishRecording(first)
    retention.end(first, completed: true)
    retention.begin(second)
    retention.append(chunk(800), to: second)
    retention.finishRecording(second)
    await queue.drain()

    #expect(retention.recordedAudio(for: second)?.sampleCount == 800)
    #expect(try queue.store.list().map(\.sessionID) == [second])
  }
}
