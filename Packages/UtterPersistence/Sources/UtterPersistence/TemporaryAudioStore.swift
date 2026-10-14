import Foundation
import UtterCore

/// STT Worker の異常終了に備えて一時保存した音声の管理（7章, AC-10）。
///
/// 音声は形式に依存しないバイト列として扱う。ファイル名には作成時刻とセッションID だけを入れ、
/// 発話内容を含めない。正常終了後は `remove(_:)` で削除し、次回起動時に `sweep()` で
/// 保持期限内のものを復旧候補、期限を過ぎたものを削除する。
/// 保存先のディレクトリと時刻は注入する。
public struct TemporaryAudioStore: Sendable {
  /// 保持期限の既定値（7章: 暫定24時間）
  public static let defaultRetention: Duration = .seconds(24 * 60 * 60)

  static let filePrefix = "utter-audio-"
  static let fileExtension = "bin"

  /// 一時音声だけを置くディレクトリ
  public let directory: URL
  public let retention: Duration
  private let now: @Sendable () -> Date
  private let protectFile: @Sendable (URL) throws -> Void

  /// - Parameters:
  ///   - directory: 一時音声だけを置くディレクトリ。なければ作る
  ///   - retention: 保持期限
  ///   - now: 現在時刻
  ///   - protectFile: 保存したファイルにファイル保護属性を付ける処理（OS ごとにアプリ側で渡す）
  public init(
    directory: URL,
    retention: Duration = TemporaryAudioStore.defaultRetention,
    now: @escaping @Sendable () -> Date = { Date() },
    protectFile: @escaping @Sendable (URL) throws -> Void = { _ in }
  ) throws(TemporaryAudioStoreError) {
    guard retention > .zero else { throw .nonPositiveRetention }
    self.directory = directory
    self.retention = retention
    self.now = now
    self.protectFile = protectFile
  }

  /// 音声を保存する。同じセッションの音声があれば置き換える。
  @discardableResult
  public func save(_ audio: Data, for session: SessionID) throws(TemporaryAudioStoreError)
    -> TemporaryAudioRecord
  {
    let record = TemporaryAudioRecord(
      sessionID: session, createdAt: now(), directory: directory)
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try? remove(session)
      try audio.write(to: record.url, options: .atomic)
      try protectFile(record.url)
    } catch {
      try? FileManager.default.removeItem(at: record.url)
      throw .writeFailed
    }
    return record
  }

  /// 正常終了後に、そのセッションの音声を削除する。なければ何もしない。
  public func remove(_ session: SessionID) throws(TemporaryAudioStoreError) {
    for record in try list() where record.sessionID == session {
      do {
        try FileManager.default.removeItem(at: record.url)
      } catch {
        throw .removeFailed
      }
    }
  }

  /// 保存済みの音声を作成時刻の古い順に返す。この形式の名前でないファイルは無視する。
  public func list() throws(TemporaryAudioStoreError) -> [TemporaryAudioRecord] {
    guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
    let names: [String]
    do {
      names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    } catch {
      throw .listFailed
    }
    return names.compactMap { TemporaryAudioRecord(fileName: $0, directory: directory) }
      .sorted {
        ($0.createdAt, $0.sessionID.rawValue.uuidString) < (
          $1.createdAt, $1.sessionID.rawValue.uuidString
        )
      }
  }

  /// 起動時の整理。保持期限を過ぎたものを削除し、期限内のものを復旧候補として返す（7章）。
  ///
  /// 作成時刻が現在より後のもの（時計の巻き戻しなど）は期限内として残す。
  public func sweep() throws(TemporaryAudioStoreError) -> TemporaryAudioSweepResult {
    let current = now()
    var recoverable: [TemporaryAudioRecord] = []
    var deleted: [TemporaryAudioRecord] = []
    for record in try list() {
      if record.isExpired(at: current, retention: retention) {
        do {
          try FileManager.default.removeItem(at: record.url)
        } catch {
          throw .removeFailed
        }
        deleted.append(record)
      } else {
        recoverable.append(record)
      }
    }
    return TemporaryAudioSweepResult(recoverable: recoverable, deleted: deleted)
  }

  /// 復旧のために音声を読み込む。
  public func load(_ record: TemporaryAudioRecord) throws(TemporaryAudioStoreError) -> Data {
    do {
      return try Data(contentsOf: record.url)
    } catch {
      throw .readFailed
    }
  }
}

/// 保存した一時音声。音声そのものは持たない。
public struct TemporaryAudioRecord: Hashable, Sendable {
  public let sessionID: SessionID
  /// 作成時刻（ミリ秒単位で切り捨て）
  public let createdAt: Date
  public let url: URL

  init(sessionID: SessionID, createdAt: Date, directory: URL) {
    let milliseconds = Int64((createdAt.timeIntervalSince1970 * 1000).rounded(.down))
    self.sessionID = sessionID
    self.createdAt = Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
    url = directory.appendingPathComponent(
      "\(TemporaryAudioStore.filePrefix)\(milliseconds)-\(sessionID.rawValue.uuidString)."
        + TemporaryAudioStore.fileExtension)
  }

  /// `utter-audio-<作成時刻のミリ秒>-<セッションID>.bin` の形式の名前から復元する。
  init?(fileName: String, directory: URL) {
    let suffix = "." + TemporaryAudioStore.fileExtension
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

  func isExpired(at now: Date, retention: Duration) -> Bool {
    let (seconds, attoseconds) = retention.components
    let interval = TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    return now.timeIntervalSince(createdAt) >= interval
  }
}

// ファイルの場所はログに出さないよう、文字列表現には作成時刻だけを出す。
extension TemporaryAudioRecord: CustomStringConvertible {
  public var description: String {
    "TemporaryAudioRecord(createdAt: \(createdAt.timeIntervalSince1970))"
  }
}

/// 起動時の整理の結果。
public struct TemporaryAudioSweepResult: Hashable, Sendable {
  /// 保持期限内で、復旧を試せるもの
  public let recoverable: [TemporaryAudioRecord]
  /// 保持期限を過ぎて削除したもの
  public let deleted: [TemporaryAudioRecord]
}

/// 一時音声の操作の失敗。パスや音声は含めない。
public enum TemporaryAudioStoreError: Error, Hashable, Sendable {
  case nonPositiveRetention
  case writeFailed
  case readFailed
  case removeFailed
  case listFailed
}
