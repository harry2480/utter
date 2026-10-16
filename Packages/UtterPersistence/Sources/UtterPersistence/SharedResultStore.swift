import Foundation
import UtterCore

/// iOS キーボード拡張と本体アプリ間で共有結果を保存・復元（iOS-IPC-04〜06）。
///
/// App Group 経由のディレクトリを使用。全操作はスレッドセーフな actor で実装。
/// 本体アプリとキーボード拡張は別プロセスで同じファイルを書き換えるため、
/// 読み込みはキャッシュせず毎回ファイルから読み、保存は `revision` の比較交換で行う。
public actor SharedResultStore: Sendable {
  private let directory: URL

  /// App Group 経由のディレクトリを使用して初期化
  /// - Parameters:
  ///   - groupIdentifier: App Group 識別子（iCloud 同期なし、本デバイス限定）
  public init?(groupIdentifier: String) {
    guard
      let url = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: groupIdentifier)
    else {
      return nil
    }
    self.init(directory: url.appendingPathComponent("SharedResults"))
  }

  init(directory: URL) {
    self.directory = directory
  }

  /// 結果を保存する。保存済みの `revision` が `expectedRevision` と一致し、
  /// 保存する結果の `revision` がそれより進んでいるときだけ書き込む（比較交換）。
  ///
  /// 照合と書き込みの間は、プロセス間で共有するファイルロックで排他にする。
  /// - Parameters:
  ///   - result: 保存する結果
  ///   - expectedRevision: 読み込んだときの `revision`。新しく作る結果なら `nil`（保存済みの結果がないこと）
  /// - Throws: 保存済みの結果が別の `revision` のとき、または保存する結果の `revision` が
  ///   `expectedRevision` より進んでいないとき `SharedResultStoreError.revisionConflict`
  public func save(_ result: SharedResult, expectedRevision: UInt64?) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let url = fileURL(for: result.sessionID)
    try withFileLock(for: result.sessionID) {
      let storedRevision = try read(from: url)?.revision
      // 古い結果を新しい revision の前提で渡されても、状態を巻き戻さない
      guard storedRevision == expectedRevision,
        expectedRevision.map({ result.revision > $0 }) ?? true
      else {
        throw SharedResultStoreError.revisionConflict
      }
      let data = try JSONEncoder().encode(result)
      try data.write(to: url, options: [.atomic])
    }
  }

  /// 結果を読み込む（存在しなければ nil）。別プロセスの更新を反映するため、毎回ファイルから読む
  public func load(sessionID: SessionID) throws -> SharedResult? {
    try read(from: fileURL(for: sessionID))
  }

  /// 結果を削除
  public func delete(sessionID: SessionID) throws {
    let url = fileURL(for: sessionID)
    try withFileLock(for: sessionID) {
      do {
        try FileManager.default.removeItem(at: url)
      } catch let error as NSError {
        guard error.code == NSFileNoSuchFileError else { throw error }
      }
    }
  }

  /// 存在確認の後に別プロセスが削除する競合を避けるため、先に読み込み、ファイルがないときだけ `nil` にする
  private func read(from url: URL) throws -> SharedResult? {
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      return nil
    }
    return try JSONDecoder().decode(SharedResult.self, from: data)
  }

  /// セッションごとのロックファイルを `flock` で排他ロックして `body` を実行する。
  ///
  /// `flock` は別プロセス間でも効くため、本体アプリとキーボード拡張の同時保存を直列化できる。
  private func withFileLock<T>(for sessionID: SessionID, _ body: () throws -> T) throws -> T {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let lockURL = directory.appendingPathComponent("\(sessionID.rawValue.uuidString).lock")
    let descriptor = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
    guard descriptor >= 0 else {
      throw SharedResultStoreError.lockFailed
    }
    defer { close(descriptor) }
    guard flock(descriptor, LOCK_EX) == 0 else {
      throw SharedResultStoreError.lockFailed
    }
    defer { flock(descriptor, LOCK_UN) }
    return try body()
  }

  private func fileURL(for sessionID: SessionID) -> URL {
    return directory.appendingPathComponent("\(sessionID.rawValue.uuidString).json")
  }
}

public enum SharedResultStoreError: Error, Hashable, Sendable {
  /// 読み込んだ後に別のプロセスが結果を更新した。読み込み直してから状態を変える
  case revisionConflict
  /// プロセス間の排他ロックを取れなかった
  case lockFailed
}
