import Foundation
import Synchronization
import Testing
import UtterCore

@testable import UtterPersistence

struct TemporaryAudioRecoveryTests {
  private let directory = TemporaryDirectory()
  private let start = Date(timeIntervalSince1970: 1_800_000_000)
  /// 戻せない音声の目印。テスト用の `decode` は先頭がこのバイトなら失敗する
  private static let broken: UInt8 = 0xFF

  private struct DecodeFailure: Error {}
  private struct ProcessFailure: Error {}

  private func recovery(
    clock: TemporaryAudioStoreTests.Clock,
    removeFile: @escaping @Sendable (URL) throws -> Void = {
      try FileManager.default.removeItem(at: $0)
    }
  ) throws -> TemporaryAudioRecovery {
    TemporaryAudioRecovery(
      store: try TemporaryAudioStore(
        directory: directory.url, retention: TemporaryAudioStore.defaultRetention,
        now: { clock.current.withLock { $0 } }, writeOptions: [], protectFile: { _ in },
        removeFile: removeFile))
  }

  /// 同じセッションの音声を複数残すため、保存先に直接書く（`save` は古いものを置き換える）
  @discardableResult
  private func place(_ data: Data, for session: SessionID, secondsAfterStart: TimeInterval)
    throws -> TemporaryAudioRecord
  {
    let record = try #require(
      TemporaryAudioRecord(
        sessionID: session, createdAt: start.addingTimeInterval(secondsAfterStart),
        directory: directory.url))
    try FileManager.default.createDirectory(at: directory.url, withIntermediateDirectories: true)
    try data.write(to: record.url)
    return record
  }

  private static func decode(_ data: Data) throws -> Data {
    guard data.first != broken else { throw DecodeFailure() }
    return data
  }

  @Test("AC-10: 起動時に保持期限を過ぎたものを削除し、残りをセッションごとに新しい順でまとめる")
  func candidatesGroupBySession() throws {
    let clock = TemporaryAudioStoreTests.Clock(start.addingTimeInterval(86_400 + 10))
    let recovery = try recovery(clock: clock)
    let first = SessionID()
    let second = SessionID()
    let expired = try place(Data([0x01]), for: SessionID(), secondsAfterStart: 0)
    let firstOld = try place(Data([0x02]), for: first, secondsAfterStart: 20)
    let secondOnly = try place(Data([0x03]), for: second, secondsAfterStart: 30)
    let firstNew = try place(Data([0x04]), for: first, secondsAfterStart: 40)

    let candidates = try recovery.candidates()

    #expect(
      candidates == [
        TemporaryAudioRecoveryCandidate(sessionID: first, records: [firstNew, firstOld]),
        TemporaryAudioRecoveryCandidate(sessionID: second, records: [secondOnly]),
      ])
    #expect(candidates.first?.createdAt == firstNew.createdAt)
    #expect(!FileManager.default.fileExists(atPath: expired.url.path))
  }

  @Test("AC-10: 保存がなければ復旧するセッションはない")
  func noCandidates() throws {
    #expect(try recovery(clock: .init(start)).candidates().isEmpty)
  }

  @Test("AC-10: 新しい音声から戻し、戻せたら古い音声は試さない")
  func triesNewestFirst() async throws {
    let recovery = try recovery(clock: .init(start.addingTimeInterval(60)))
    let session = SessionID()
    try place(Data([0x01]), for: session, secondsAfterStart: 0)
    let newest = try place(Data([0x02]), for: session, secondsAfterStart: 10)
    let candidate = try #require(try recovery.candidates().first)
    let decoded = Mutex<[Data]>([])

    let result = await recovery.recover(
      candidate,
      decode: { data in
        decoded.withLock { $0.append(data) }
        return try Self.decode(data)
      },
      process: { audio, _ in audio })

    #expect(result == .recovered(Data([0x02]), from: newest, removed: true))
    #expect(decoded.withLock { $0 } == [Data([0x02])])
  }

  @Test("AC-10: 戻せない音声は飛ばし、次に古い音声を試す")
  func skipsUndecodable() async throws {
    let recovery = try recovery(clock: .init(start.addingTimeInterval(60)))
    let session = SessionID()
    let oldest = try place(Data([0x01]), for: session, secondsAfterStart: 0)
    try place(Data([0x02, 0x03]), for: session, secondsAfterStart: 10)
    try place(Data([Self.broken]), for: session, secondsAfterStart: 20)
    let candidate = try #require(try recovery.candidates().first)
    let decoded = Mutex<[Data]>([])

    let result = await recovery.recover(
      candidate,
      decode: { data in
        decoded.withLock { $0.append(data) }
        // 2番目も戻せない（形式の版が違うなど）ものとして扱う
        guard data.count == 1 else { throw DecodeFailure() }
        return try Self.decode(data)
      },
      process: { audio, _ in audio })

    #expect(result == .recovered(Data([0x01]), from: oldest, removed: true))
    #expect(decoded.withLock { $0 } == [Data([Self.broken]), Data([0x02, 0x03]), Data([0x01])])
  }

  @Test("AC-10: 確認を待つ間に無くなった音声は飛ばし、次に古い音声を試す")
  func skipsUnreadable() async throws {
    let recovery = try recovery(clock: .init(start.addingTimeInterval(60)))
    let session = SessionID()
    let older = try place(Data([0x01]), for: session, secondsAfterStart: 0)
    let newer = try place(Data([0x02]), for: session, secondsAfterStart: 10)
    let candidate = try #require(try recovery.candidates().first)
    try FileManager.default.removeItem(at: newer.url)

    let result = await recovery.recover(
      candidate, decode: Self.decode, process: { audio, _ in audio })

    #expect(result == .recovered(Data([0x01]), from: older, removed: true))
  }

  @Test("AC-10: すべて戻せなければ、認識をやり直さずにそのセッションの音声を削除する")
  func allUndecodable() async throws {
    let recovery = try recovery(clock: .init(start.addingTimeInterval(60)))
    let session = SessionID()
    let other = try place(Data([0x09]), for: SessionID(), secondsAfterStart: 5)
    try place(Data([Self.broken]), for: session, secondsAfterStart: 0)
    try place(Data([Self.broken, 0x01]), for: session, secondsAfterStart: 10)
    let candidate = try #require(try recovery.candidates().first { $0.sessionID == session })
    let processed = Mutex(false)

    let result: TemporaryAudioRecoveryResult<Data> = await recovery.recover(
      candidate, decode: Self.decode,
      process: { audio, _ in
        processed.withLock { $0 = true }
        return audio
      })

    #expect(result == .unrecoverable(removed: true))
    #expect(!processed.withLock { $0 })
    #expect(try recovery.store.list() == [other])
  }

  @Test("AC-10: 認識をやり直せたら、そのセッションの音声をまとめて削除し、ほかのセッションは残す")
  func removesSessionAfterSuccess() async throws {
    let recovery = try recovery(clock: .init(start.addingTimeInterval(60)))
    let session = SessionID()
    let other = try place(Data([0x09]), for: SessionID(), secondsAfterStart: 5)
    try place(Data([0x01]), for: session, secondsAfterStart: 0)
    let newest = try place(Data([0x02]), for: session, secondsAfterStart: 10)
    let candidate = try #require(try recovery.candidates().first { $0.sessionID == session })

    let result = await recovery.recover(
      candidate, decode: Self.decode, process: { _, _ in "認識結果" })

    #expect(result == .recovered("認識結果", from: newest, removed: true))
    #expect(try recovery.store.list() == [other])
  }

  @Test("AC-10: 認識のやり直しには元のセッションID をそのまま渡す")
  func reusesSessionID() async throws {
    let recovery = try recovery(clock: .init(start.addingTimeInterval(60)))
    let session = SessionID()
    try place(Data([0x01]), for: session, secondsAfterStart: 0)
    let candidate = try #require(try recovery.candidates().first)

    let result = await recovery.recover(
      candidate, decode: Self.decode, process: { _, received in received })

    guard case .recovered(let received, _, _) = result else {
      Issue.record("復旧できなかった: \(result)")
      return
    }
    #expect(received == session)
  }

  @Test("AC-10: 認識のやり直しに失敗したら、やり直せるよう音声を残す")
  func keepsAudioWhenProcessingFails() async throws {
    let recovery = try recovery(clock: .init(start.addingTimeInterval(60)))
    let session = SessionID()
    let record = try place(Data([0x01]), for: session, secondsAfterStart: 0)
    let candidate = try #require(try recovery.candidates().first)

    let result: TemporaryAudioRecoveryResult<Data> = await recovery.recover(
      candidate, decode: Self.decode, process: { _, _ in throw ProcessFailure() })

    #expect(result == .processingFailed)
    #expect(try recovery.store.list() == [record])
  }

  @Test("AC-10: 認識のやり直しがキャンセルされたら、音声を残す")
  func keepsAudioWhenProcessingIsCancelled() async throws {
    let recovery = try recovery(clock: .init(start.addingTimeInterval(60)))
    let record = try place(Data([0x01]), for: SessionID(), secondsAfterStart: 0)
    let candidate = try #require(try recovery.candidates().first)

    let result: TemporaryAudioRecoveryResult<Data> = await recovery.recover(
      candidate, decode: Self.decode, process: { _, _ in throw CancellationError() })

    #expect(result == .cancelled)
    #expect(try recovery.store.list() == [record])
  }

  @Test("AC-10: キャンセル済みなら音声を読まずに終え、音声を残す")
  func cancelledBeforeStart() async throws {
    let recovery = try recovery(clock: .init(start.addingTimeInterval(60)))
    let record = try place(Data([0x01]), for: SessionID(), secondsAfterStart: 0)
    let candidate = try #require(try recovery.candidates().first)
    let decoded = Mutex(false)

    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return await recovery.recover(
        candidate,
        decode: { data in
          decoded.withLock { $0 = true }
          return data
        },
        process: { audio, _ in audio })
    }

    #expect(await task.value == .cancelled)
    #expect(!decoded.withLock { $0 })
    #expect(try recovery.store.list() == [record])
  }

  @Test("AC-10: 確認を待つ間に保持期限を過ぎた音声は、試さずに削除する")
  func skipsExpiredAtRecovery() async throws {
    let clock = TemporaryAudioStoreTests.Clock(start.addingTimeInterval(60))
    let recovery = try recovery(clock: clock)
    let session = SessionID()
    let older = try place(Data([0x01]), for: session, secondsAfterStart: 0)
    let newer = try place(Data([0x02]), for: session, secondsAfterStart: 10)
    let candidate = try #require(try recovery.candidates().first)
    clock.advance(by: 86_400 + 5 - 60)

    let result = await recovery.recover(
      candidate, decode: Self.decode, process: { audio, _ in audio })

    #expect(result == .recovered(Data([0x02]), from: newer, removed: true))
    #expect(!FileManager.default.fileExists(atPath: older.url.path))

    // すべて期限切れなら、戻せなかったものとして扱う
    let late = SessionID()
    try place(Data([0x03]), for: late, secondsAfterStart: 86_400 - 30)
    let lateCandidate = try #require(try recovery.candidates().first)
    clock.advance(by: 86_400)
    let lateResult: TemporaryAudioRecoveryResult<Data> = await recovery.recover(
      lateCandidate, decode: Self.decode, process: { audio, _ in audio })
    #expect(lateResult == .unrecoverable(removed: true))
    #expect(try recovery.store.list().isEmpty)
  }

  @Test("AC-10: 認識のやり直し後に音声を削除できなければ、結果で知らせる")
  func reportsRemovalFailure() async throws {
    struct RemoveFailure: Error {}
    let recovery = try recovery(
      clock: .init(start.addingTimeInterval(60)), removeFile: { _ in throw RemoveFailure() })
    let record = try place(Data([0x01]), for: SessionID(), secondsAfterStart: 0)
    let candidate = try #require(try recovery.candidates().first)

    let result = await recovery.recover(
      candidate, decode: Self.decode, process: { audio, _ in audio })

    #expect(result == .recovered(Data([0x01]), from: record, removed: false))
  }

  @Test("AC-10: すべて戻せず削除にも失敗したら、結果で知らせる")
  func reportsRemovalFailureWhenUnrecoverable() async throws {
    struct RemoveFailure: Error {}
    let recovery = try recovery(
      clock: .init(start.addingTimeInterval(60)), removeFile: { _ in throw RemoveFailure() })
    let record = try place(Data([Self.broken]), for: SessionID(), secondsAfterStart: 0)
    let candidate = try #require(try recovery.candidates().first)

    let result: TemporaryAudioRecoveryResult<Data> = await recovery.recover(
      candidate, decode: Self.decode, process: { audio, _ in audio })

    #expect(result == .unrecoverable(removed: false))
    #expect(try recovery.store.list() == [record])
  }

  @Test("AC-10: 読み込めない音声（端末のロック中など）があれば、戻せないと決めずに音声を残す")
  func keepsUnreadableAudio() async throws {
    let recovery = try recovery(clock: .init(start.addingTimeInterval(60)))
    let session = SessionID()
    let older = try place(Data([Self.broken]), for: session, secondsAfterStart: 0)
    let newer = try place(Data([0x02]), for: session, secondsAfterStart: 10)
    let candidate = try #require(try recovery.candidates().first)
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: newer.url.path)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: newer.url.path)
    }

    let result: TemporaryAudioRecoveryResult<Data> = await recovery.recover(
      candidate, decode: Self.decode, process: { audio, _ in audio })

    #expect(result == .unreadable)
    #expect(try recovery.store.list() == [older, newer])
  }

  @Test("AC-10: 復旧の候補と結果の文字列表現に、セッションID と復旧した値を出さない")
  func redactsDescriptions() throws {
    let session = SessionID()
    let record = try #require(
      TemporaryAudioRecord(sessionID: session, createdAt: start, directory: directory.url))
    let candidate = TemporaryAudioRecoveryCandidate(sessionID: session, records: [record])
    let result = TemporaryAudioRecoveryResult.recovered("秘密", from: record, removed: true)

    for text in [
      String(describing: candidate), String(reflecting: candidate),
      String(describing: result), String(reflecting: result),
    ] {
      #expect(!text.contains(session.rawValue.uuidString))
      #expect(!text.contains("秘密"))
      #expect(!text.contains(directory.url.path))
    }
    #expect(String(describing: TemporaryAudioRecoveryResult<String>.cancelled) == "cancelled")
  }
}
