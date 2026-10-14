import Foundation
import UtterCore

/// STT Worker の異常終了に備えて一時保存した音声の管理（7章, AC-10）。
///
/// 音声は形式に依存しないバイト列として扱う。ファイル名には作成時刻とセッションID だけを入れ、
/// 発話内容を含めない。正常終了後は `remove(_:)` で削除し、次回起動時に `sweep()` で
/// 保持期限内のものを復旧候補、期限を過ぎたものを削除する。保存先のディレクトリと時刻は注入する。
///
/// 同じストアへの操作は、呼び出し側で1つずつ実行する（同時に呼んだときの順序は保証しない）。
public struct TemporaryAudioStore: Sendable {
  /// 保持期限の既定値（7章: 暫定24時間）
  public static let defaultRetention: Duration = .seconds(24 * 60 * 60)

  static let filePrefix = "utter-audio-"
  static let fileExtension = "bin"
  /// 書き込み途中のファイルの拡張子。書き終えたら本来の名前に変える
  static let partialExtension = "partial"

  /// 一時音声だけを置くディレクトリ
  public let directory: URL
  public let retention: Duration
  private let now: @Sendable () -> Date
  private let writeOptions: Data.WritingOptions
  private let protectFile: @Sendable (URL) throws -> Void
  private let removeFile: @Sendable (URL) throws -> Void

  /// - Parameters:
  ///   - directory: 一時音声だけを置くディレクトリ。なければ所有者だけが読み書きできる権限で作る
  ///   - retention: 保持期限
  ///   - now: 現在時刻
  ///   - writeOptions: 書き込みのオプション。iOS では書き込みと同時にファイル保護を付けるオプションを渡す
  ///   - protectFile: 保存したファイルに保護属性を付ける処理。バックアップからの除外もここで行う
  public init(
    directory: URL,
    retention: Duration = TemporaryAudioStore.defaultRetention,
    now: @escaping @Sendable () -> Date = { Date() },
    writeOptions: Data.WritingOptions = [],
    protectFile: @escaping @Sendable (URL) throws -> Void = { _ in }
  ) throws(TemporaryAudioStoreError) {
    try self.init(
      directory: directory, retention: retention, now: now, writeOptions: writeOptions,
      protectFile: protectFile, removeFile: { try FileManager.default.removeItem(at: $0) })
  }

  init(
    directory: URL,
    retention: Duration,
    now: @escaping @Sendable () -> Date,
    writeOptions: Data.WritingOptions,
    protectFile: @escaping @Sendable (URL) throws -> Void,
    removeFile: @escaping @Sendable (URL) throws -> Void
  ) throws(TemporaryAudioStoreError) {
    guard retention > .zero else { throw .nonPositiveRetention }
    self.directory = directory
    self.retention = retention
    self.now = now
    self.writeOptions = writeOptions
    self.protectFile = protectFile
    self.removeFile = removeFile
  }

  /// 音声を保存する。同じセッションの古い音声は、新しい音声を保存できた後で削除する。
  ///
  /// 古い音声を削除できなかった場合も保存は成功とし、古い音声は保持期限で `sweep()` が削除する。
  @discardableResult
  public func save(_ audio: Data, for session: SessionID) throws(TemporaryAudioStoreError)
    -> TemporaryAudioRecord
  {
    guard
      let record = TemporaryAudioRecord(sessionID: session, createdAt: now(), directory: directory)
    else { throw .writeFailed }
    let previous = (try? list().filter { $0.sessionID == session && $0.url != record.url }) ?? []
    let partial = record.url.deletingPathExtension().appendingPathExtension(Self.partialExtension)
    do {
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      try audio.write(to: partial, options: writeOptions)
      try protectFile(partial)
      if FileManager.default.fileExists(atPath: record.url.path) {
        try FileManager.default.removeItem(at: record.url)
      }
      try FileManager.default.moveItem(at: partial, to: record.url)
    } catch {
      try? FileManager.default.removeItem(at: partial)
      throw .writeFailed
    }
    for old in previous {
      try? delete(old.url)
    }
    return record
  }

  /// 正常終了後に、そのセッションの音声を削除する。なければ何もしない。
  ///
  /// 削除できないものがあっても残りは削除を続け、最後に `removeFailed` を投げる。
  public func remove(_ session: SessionID) throws(TemporaryAudioStoreError) {
    var failed = false
    for record in try list() where record.sessionID == session {
      do {
        try delete(record.url)
      } catch {
        failed = true
      }
    }
    if failed {
      throw .removeFailed
    }
  }

  /// 保存済みの音声を作成時刻の古い順に返す。この形式の名前でないファイルと書き込み途中のファイルは含めない。
  public func list() throws(TemporaryAudioStoreError) -> [TemporaryAudioRecord] {
    try fileNames().compactMap { TemporaryAudioRecord(fileName: $0, directory: directory) }
      .sorted {
        ($0.createdAt, $0.sessionID.rawValue.uuidString)
          < ($1.createdAt, $1.sessionID.rawValue.uuidString)
      }
  }

  /// 起動時の整理（7章）。保持期限を過ぎたものと、作成時刻が保持期限より先の未来にある
  /// 明らかに不正なものを削除し、残りを復旧候補として返す。保持期限を過ぎた書き込み途中のファイルも削除する。
  ///
  /// 削除できないものがあっても残りの整理を続け、`failed` で返す。
  public func sweep() throws(TemporaryAudioStoreError) -> TemporaryAudioSweepResult {
    let current = now()
    var recoverable: [TemporaryAudioRecord] = []
    var deleted: [TemporaryAudioRecord] = []
    var failed: [TemporaryAudioRecord] = []
    for record in try list() {
      guard record.shouldDelete(at: current, retention: retention) else {
        recoverable.append(record)
        continue
      }
      do {
        try delete(record.url)
        deleted.append(record)
      } catch {
        failed.append(record)
      }
    }
    for name in try fileNames() {
      guard let partial = TemporaryAudioRecord(partialFileName: name, directory: directory),
        partial.shouldDelete(at: current, retention: retention)
      else { continue }
      try? delete(partial.url)
    }
    return TemporaryAudioSweepResult(recoverable: recoverable, deleted: deleted, failed: failed)
  }

  /// 復旧のために音声を読み込む。
  public func load(_ record: TemporaryAudioRecord) throws(TemporaryAudioStoreError) -> Data {
    do {
      return try Data(contentsOf: record.url)
    } catch {
      throw .readFailed
    }
  }

  private func fileNames() throws(TemporaryAudioStoreError) -> [String] {
    guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
    do {
      return try FileManager.default.contentsOfDirectory(atPath: directory.path)
    } catch {
      throw .listFailed
    }
  }

  /// ファイルを削除する。すでに存在しなければ削除できたものとして扱う。
  private func delete(_ url: URL) throws {
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    try removeFile(url)
  }
}

/// 保存した一時音声。音声そのものは持たない。
public struct TemporaryAudioRecord: Hashable, Sendable {
  public let sessionID: SessionID
  /// 作成時刻（ミリ秒単位で切り捨て）
  public let createdAt: Date
  public let url: URL

  /// 作成時刻が 1970 年より前、または有限でなければ `nil`。
  init?(sessionID: SessionID, createdAt: Date, directory: URL) {
    let value = (createdAt.timeIntervalSince1970 * 1000).rounded(.down)
    guard value.isFinite, value >= 0, value < Double(Int64.max) else { return nil }
    let milliseconds = Int64(value)
    self.sessionID = sessionID
    self.createdAt = Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
    url = directory.appendingPathComponent(
      "\(TemporaryAudioStore.filePrefix)\(milliseconds)-\(sessionID.rawValue.uuidString)."
        + TemporaryAudioStore.fileExtension)
  }

  /// `utter-audio-<作成時刻のミリ秒>-<セッションID>.bin` の形式の名前から復元する。
  init?(fileName: String, directory: URL) {
    self.init(
      fileName: fileName, extension: TemporaryAudioStore.fileExtension, directory: directory)
  }

  /// 書き込み途中のファイル（`.partial`）の名前から復元する。
  init?(partialFileName: String, directory: URL) {
    self.init(
      fileName: partialFileName, extension: TemporaryAudioStore.partialExtension,
      directory: directory)
  }

  private init?(fileName: String, extension: String, directory: URL) {
    let suffix = "." + `extension`
    guard fileName.hasPrefix(TemporaryAudioStore.filePrefix), fileName.hasSuffix(suffix) else {
      return nil
    }
    let body = fileName.dropFirst(TemporaryAudioStore.filePrefix.count).dropLast(suffix.count)
    guard let separator = body.firstIndex(of: "-"),
      let milliseconds = Int64(body[..<separator]), milliseconds >= 0,
      let uuid = UUID(uuidString: String(body[body.index(after: separator)...]))
    else { return nil }
    sessionID = SessionID(rawValue: uuid)
    createdAt = Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
    url = directory.appendingPathComponent(fileName)
  }

  /// 保持期限を過ぎた、または作成時刻が保持期限より先の未来にある（時計が大きく進んでいた）なら削除する。
  /// 少しだけ未来のもの（時計の巻き戻し）は残す。
  func shouldDelete(at now: Date, retention: Duration) -> Bool {
    let (seconds, attoseconds) = retention.components
    let interval = TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    let age = now.timeIntervalSince(createdAt)
    return age >= interval || -age > interval
  }
}

// ファイルの場所とセッションID をログに出さないよう、文字列表現とリフレクションには作成時刻だけを出す。
extension TemporaryAudioRecord: CustomStringConvertible, CustomReflectable {
  public var description: String {
    "TemporaryAudioRecord(createdAt: \(createdAt.timeIntervalSince1970))"
  }

  public var customMirror: Mirror {
    Mirror(self, children: ["createdAt": createdAt])
  }
}

/// 起動時の整理の結果。
public struct TemporaryAudioSweepResult: Hashable, Sendable {
  /// 保持期限内で、復旧を試せるもの
  public let recoverable: [TemporaryAudioRecord]
  /// 削除したもの
  public let deleted: [TemporaryAudioRecord]
  /// 削除すべきだが削除できなかったもの。次回の整理で再び試す
  public let failed: [TemporaryAudioRecord]
}

/// 一時音声の操作の失敗。パスや音声は含めない。
public enum TemporaryAudioStoreError: Error, Hashable, Sendable {
  case nonPositiveRetention
  case writeFailed
  case readFailed
  case removeFailed
  case listFailed
}
