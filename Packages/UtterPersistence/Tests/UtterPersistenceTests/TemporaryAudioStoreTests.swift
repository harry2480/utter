import Foundation
import Synchronization
import Testing
import UtterCore

@testable import UtterPersistence

/// テストごとに一時ディレクトリを作り、終わったら消す。
///
/// Swift Testing はテストごとにスイートのインスタンスを作るため、テストの終了時に `deinit` で消える。
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
    protectFile: @escaping @Sendable (URL) throws -> Void = { _ in },
    removeFile: @escaping @Sendable (URL) throws -> Void = {
      try FileManager.default.removeItem(at: $0)
    }
  ) throws -> TemporaryAudioStore {
    try TemporaryAudioStore(
      directory: directory.url, retention: retention,
      now: { clock.current.withLock { $0 } }, writeOptions: [], protectFile: protectFile,
      removeFile: removeFile)
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

  @Test("AC-10: 起動時に保持期限内のものを復旧候補、期限を過ぎたものを削除する")
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
    "AC-10: 保持期限の境界はちょうど期限で削除する",
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

  @Test("AC-10: 保持期限は設定できる")
  func configurableRetention() throws {
    let clock = Clock(start)
    let store = try store(clock: clock, retention: .seconds(60))
    try store.save(audio, for: SessionID())
    clock.advance(by: 60)

    #expect(try store.sweep().deleted.count == 1)
  }

  @Test("AC-10: 保持期限の既定は24時間")
  func defaultRetention() {
    #expect(TemporaryAudioStore.defaultRetention == .seconds(86_400))
  }

  @Test("AC-10: 0 以下の保持期限は拒否する", arguments: [Duration.zero, .seconds(-1)])
  func rejectsNonPositiveRetention(_ retention: Duration) {
    #expect(throws: TemporaryAudioStoreError.nonPositiveRetention) {
      try TemporaryAudioStore(directory: directory.url, retention: retention)
    }
  }

  @Test(
    "AC-10: 作成時刻が少し未来なら残し、保持期限より先の未来なら削除する",
    arguments: [(-3600.0, false), (-86_400.0, false), (-86_401.0, true), (-3_000_000_000.0, true)])
  func futureTimestamp(_ clockShift: TimeInterval, _ deleted: Bool) throws {
    let clock = Clock(start)
    let store = try store(clock: clock)
    try store.save(audio, for: SessionID())

    clock.advance(by: clockShift)
    let result = try store.sweep()

    #expect(result.deleted.count == (deleted ? 1 : 0))
    #expect(result.recoverable.count == (deleted ? 0 : 1))
  }

  @Test("AC-10: この形式でないファイルは一覧・整理の対象にしない")
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
    #expect(
      try store.sweep() == TemporaryAudioSweepResult(recoverable: [], deleted: [], failed: []))
    try store.save(audio, for: SessionID())
    #expect(FileManager.default.fileExists(atPath: directory.url.path))
  }

  @Test("AC-10: 保存したファイルに、公開する前にファイル保護属性を付ける処理を呼ぶ")
  func callsFileProtection() throws {
    let protected = Mutex<[URL]>([])
    let store = try store(
      clock: Clock(start), protectFile: { url in protected.withLock { $0.append(url) } })

    let record = try store.save(audio, for: SessionID())

    // 本来の名前に変える前（書き込み直後）に付け、名前を変えても属性は引き継がれる
    #expect(
      protected.withLock { $0 }
        == [record.url.deletingPathExtension().appendingPathExtension("partial")])
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

  @Test("AC-10: 記録の文字列表現とリフレクションにファイルの場所とセッションID を出さない")
  func redactsRecord() throws {
    let session = SessionID()
    let record = try store(clock: Clock(start)).save(audio, for: session)
    var dumped = ""
    dump(record, to: &dumped)

    for output in [String(describing: record), String(reflecting: record), dumped] {
      #expect(!output.contains(directory.url.lastPathComponent))
      #expect(!output.contains(session.rawValue.uuidString))
    }
  }

  @Test("AC-10: 置き換えの保存に失敗しても、古い音声は残る")
  func failedReplacementKeepsPreviousAudio() throws {
    struct ProtectionFailure: Error {}
    let clock = Clock(start)
    let session = SessionID()
    let first = try store(clock: clock).save(audio, for: session)
    clock.advance(by: 5)
    let failing = try store(clock: clock, protectFile: { _ in throw ProtectionFailure() })

    #expect(throws: TemporaryAudioStoreError.writeFailed) {
      try failing.save(Data([0x09]), for: session)
    }
    #expect(try failing.list() == [first])
    #expect(try failing.load(first) == audio)
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.url.path)
    #expect(leftovers == [first.url.lastPathComponent])
  }

  @Test("AC-10: 削除は指定したセッションだけで、ないセッションの削除は何もしない")
  func removeOnlyTargetSession() throws {
    let store = try store(clock: Clock(start))
    let kept = try store.save(audio, for: SessionID())
    let removed = SessionID()
    try store.save(audio, for: removed)

    try store.remove(removed)
    try store.remove(SessionID())

    #expect(try store.list() == [kept])
  }

  @Test("AC-10: 整理で削除に失敗したものがあっても、残りの整理を続ける")
  func sweepContinuesAfterFailure() throws {
    struct RemoveFailure: Error {}
    let clock = Clock(start)
    let blocked = SessionID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!)
    let setup = try store(clock: clock)
    let failing = try setup.save(audio, for: blocked)
    let other = try setup.save(audio, for: SessionID())
    clock.advance(by: 60)
    let recent = try setup.save(audio, for: SessionID())
    clock.advance(by: 86_400 - 30)
    let store = try store(
      clock: clock,
      removeFile: { url in
        if url.lastPathComponent.contains(blocked.rawValue.uuidString) { throw RemoveFailure() }
        try FileManager.default.removeItem(at: url)
      })

    let result = try store.sweep()

    #expect(result.failed == [failing])
    #expect(result.deleted == [other])
    #expect(result.recoverable == [recent])
  }

  @Test("AC-10: 保持期限を過ぎた書き込み途中のファイルを整理で削除する")
  func sweepRemovesStalePartialFiles() throws {
    let clock = Clock(start)
    let store = try store(clock: clock)
    try FileManager.default.createDirectory(at: directory.url, withIntermediateDirectories: true)
    let stale = directory.url.appendingPathComponent(
      "utter-audio-1800000000000-00000000-0000-0000-0000-000000000001.partial")
    let fresh = directory.url.appendingPathComponent(
      "utter-audio-1800086000000-00000000-0000-0000-0000-000000000002.partial")
    try Data([0x01]).write(to: stale)
    try Data([0x01]).write(to: fresh)

    clock.advance(by: 86_400)
    _ = try store.sweep()

    #expect(!FileManager.default.fileExists(atPath: stale.path))
    #expect(FileManager.default.fileExists(atPath: fresh.path))
    #expect(try store.list().isEmpty)
  }

  @Test("AC-10: 1970 年より前の時刻では保存しない")
  func rejectsPre1970Timestamp() throws {
    let store = try store(clock: Clock(Date(timeIntervalSince1970: -1)))

    #expect(throws: TemporaryAudioStoreError.writeFailed) {
      try store.save(audio, for: SessionID())
    }
  }

  @Test("AC-10: 保存先のディレクトリは所有者だけが読み書きできる")
  func directoryPermissions() throws {
    try store(clock: Clock(start)).save(audio, for: SessionID())

    let attributes = try FileManager.default.attributesOfItem(atPath: directory.url.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
  }

  @Test("AC-10: 既にあるディレクトリも、保存時に所有者だけが読み書きできる権限にそろえる")
  func tightensExistingDirectoryPermissions() throws {
    try FileManager.default.createDirectory(
      at: directory.url, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o755])

    try store(clock: Clock(start)).save(audio, for: SessionID())

    let attributes = try FileManager.default.attributesOfItem(atPath: directory.url.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
  }

  @Test("AC-10: 保存したファイルは所有者だけが読み書きできる")
  func filePermissions() throws {
    let record = try store(clock: Clock(start)).save(audio, for: SessionID())

    let attributes = try FileManager.default.attributesOfItem(atPath: record.url.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
  }

  @Test("AC-10: 保存前にファイルの権限をそろえ、保護属性を付ける処理にはその状態で渡す")
  func protectsFileAfterTighteningPermissions() throws {
    let seen = Mutex<Int?>(nil)
    let store = try store(
      clock: Clock(start),
      protectFile: { url in
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        seen.withLock { $0 = (attributes[.posixPermissions] as? NSNumber)?.intValue }
      })

    try store.save(audio, for: SessionID())

    #expect(seen.withLock { $0 } == 0o600)
  }
}
