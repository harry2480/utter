import Foundation
import Synchronization
import Testing
import UtterCore

@testable import UtterPersistence

/// テストごとに一時ディレクトリを作り、終わったら消す。
final class TemporaryDirectory {
  let url: URL

  init() {
    url = FileManager.default.temporaryDirectory
      .appendingPathComponent("utter-tests-\(UUID().uuidString)", isDirectory: true)
  }

  deinit {
    try? FileManager.default.removeItem(at: url)
  }
}

struct TemporaryAudioStoreTests {
  private let directory = TemporaryDirectory()
  private let start = Date(timeIntervalSince1970: 1_800_000_000)
  private let audio = Data([0x01, 0x02, 0x03, 0x04])

  /// 進められる時計
  final class Clock: Sendable {
    let current: Mutex<Date>

    init(_ date: Date) {
      current = Mutex(date)
    }

    func advance(by seconds: TimeInterval) {
      current.withLock { $0 = $0.addingTimeInterval(seconds) }
    }
  }

  private func store(
    clock: Clock, retention: Duration = TemporaryAudioStore.defaultRetention,
    protectFile: @escaping @Sendable (URL) throws -> Void = { _ in }
  ) throws -> TemporaryAudioStore {
    try TemporaryAudioStore(
      directory: directory.url, retention: retention,
      now: { clock.current.withLock { $0 } }, protectFile: protectFile)
  }

  @Test("AC-10: 保存した音声を一覧・読み込みでき、正常終了後に削除できる")
  func saveListLoadRemove() throws {
    let store = try store(clock: Clock(start))
    let session = SessionID()

    let record = try store.save(audio, for: session)

    #expect(try store.list() == [record])
    #expect(try store.load(record) == audio)
    #expect(record.createdAt == start)
    try store.remove(session)
    #expect(try store.list().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: record.url.path))
  }

  @Test("AC-10: ファイル名には作成時刻とセッションID だけを入れる")
  func fileNameHasNoContent() throws {
    let session = SessionID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    let record = try store(clock: Clock(start)).save(audio, for: session)

    #expect(
      record.url.lastPathComponent
        == "utter-audio-1800000000000-00000000-0000-0000-0000-000000000001.bin")
    #expect(
      record.url.deletingLastPathComponent().standardizedFileURL
        == directory.url.standardizedFileURL)
  }

  @Test("AC-10: 同じセッションの音声は置き換える")
  func replacesSameSession() throws {
    let clock = Clock(start)
    let store = try store(clock: clock)
    let session = SessionID()

    try store.save(audio, for: session)
    clock.advance(by: 5)
    let latest = try store.save(Data([0x09]), for: session)

    #expect(try store.list() == [latest])
    #expect(try store.load(latest) == Data([0x09]))
  }

  @Test("7章: 起動時に保持期限内のものを復旧候補、期限を過ぎたものを削除する")
  func sweepSeparatesRecoverableAndExpired() throws {
    let clock = Clock(start)
    let store = try store(clock: clock)
    let old = try store.save(audio, for: SessionID())
    clock.advance(by: 12 * 60 * 60)
    let recent = try store.save(audio, for: SessionID())

    clock.advance(by: 12 * 60 * 60)
    let result = try store.sweep()

    #expect(result.deleted == [old])
    #expect(result.recoverable == [recent])
    #expect(try store.list() == [recent])
  }

  @Test(
    "7章: 保持期限の境界はちょうど期限で削除する",
    arguments: [(86_399.999, false), (86_400.0, true), (90_000.0, true)])
  func expiryBoundary(_ elapsed: TimeInterval, _ expired: Bool) throws {
    let clock = Clock(start)
    let store = try store(clock: clock)
    try store.save(audio, for: SessionID())

    clock.advance(by: elapsed)
    let result = try store.sweep()

    #expect(result.deleted.count == (expired ? 1 : 0))
    #expect(result.recoverable.count == (expired ? 0 : 1))
  }

  @Test("7章: 保持期限は設定でき、0 以下は拒否する")
  func configurableRetention() throws {
    let clock = Clock(start)
    let store = try store(clock: clock, retention: .seconds(60))
    try store.save(audio, for: SessionID())
    clock.advance(by: 60)

    #expect(try store.sweep().deleted.count == 1)
    #expect(TemporaryAudioStore.defaultRetention == .seconds(86_400))
    #expect(throws: TemporaryAudioStoreError.nonPositiveRetention) {
      try TemporaryAudioStore(directory: directory.url, retention: .zero)
    }
  }

  @Test("7章: 作成時刻が現在より後のもの（時計の巻き戻し）は削除しない")
  func futureTimestampIsKept() throws {
    let clock = Clock(start)
    let store = try store(clock: clock)
    try store.save(audio, for: SessionID())

    clock.advance(by: -3600)

    #expect(try store.sweep().recoverable.count == 1)
  }

  @Test("7章: この形式でないファイルは一覧・整理の対象にしない")
  func ignoresForeignFiles() throws {
    let clock = Clock(start)
    let store = try store(clock: clock)
    try FileManager.default.createDirectory(at: directory.url, withIntermediateDirectories: true)
    let names = [
      "note.txt", "utter-audio-abc-00000000-0000-0000-0000-000000000001.bin",
      "utter-audio-1-not-a-uuid.bin", "utter-audio--1-00000000-0000-0000-0000-000000000001.bin",
    ]
    for name in names {
      try Data().write(to: directory.url.appendingPathComponent(name))
    }

    clock.advance(by: 100 * 24 * 60 * 60)
    let result = try store.sweep()

    #expect(result.deleted.isEmpty)
    #expect(try store.list().isEmpty)
    for name in names {
      #expect(
        FileManager.default.fileExists(atPath: directory.url.appendingPathComponent(name).path))
    }
  }

  @Test("AC-10: ディレクトリがなければ一覧は空で、保存時に作る")
  func createsDirectoryOnSave() throws {
    let store = try store(clock: Clock(start))

    #expect(try store.list().isEmpty)
    #expect(try store.sweep() == TemporaryAudioSweepResult(recoverable: [], deleted: []))
    try store.save(audio, for: SessionID())
    #expect(FileManager.default.fileExists(atPath: directory.url.path))
  }

  @Test("AC-10: 保存したファイルにファイル保護属性を付ける処理を呼ぶ")
  func callsFileProtection() throws {
    let protected = Mutex<[URL]>([])
    let store = try store(
      clock: Clock(start), protectFile: { url in protected.withLock { $0.append(url) } })

    let record = try store.save(audio, for: SessionID())

    #expect(protected.withLock { $0 } == [record.url])
  }

  @Test("AC-10: ファイル保護属性を付けられなければ保存を取り消す")
  func failedProtectionRemovesFile() throws {
    struct ProtectionFailure: Error {}
    let store = try store(clock: Clock(start), protectFile: { _ in throw ProtectionFailure() })

    #expect(throws: TemporaryAudioStoreError.writeFailed) {
      try store.save(audio, for: SessionID())
    }
    #expect(try store.list().isEmpty)
  }

  @Test("AC-10: 記録の文字列表現にファイルの場所とセッションID を出さない")
  func redactsRecord() throws {
    let session = SessionID()
    let record = try store(clock: Clock(start)).save(audio, for: session)

    #expect(!String(describing: record).contains(directory.url.path))
    #expect(!String(describing: record).contains(session.rawValue.uuidString))
  }
}
