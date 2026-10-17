import Foundation
import UtterCore

/// iOS キーボード拡張と本体アプリ間で共有結果を保存・復元（iOS-IPC-04〜06）。
///
/// App Group 経由のディレクトリを使用。全操作はスレッドセーフな actor で実装。
/// 本体アプリとキーボード拡張は別プロセスで同じファイルを書き換えるため、
/// 読み込みはキャッシュせず毎回ファイルから読み、保存は `revision` の比較交換で行う。
public actor SharedResultStore: Sendable {
  private let directory: URL
  private let fileProtection: SharedResultFileProtection

  /// App Group 経由のディレクトリを使用して初期化
  /// - Parameters:
  ///   - groupIdentifier: App Group 識別子（iCloud 同期なし、本デバイス限定）
  ///   - fileProtection: 結果のファイルに付ける保護クラス（iOS-IPC-05）
  public init?(
    groupIdentifier: String,
    fileProtection: SharedResultFileProtection = .completeUntilFirstUserAuthentication
  ) {
    guard
      let url = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: groupIdentifier)
    else {
      return nil
    }
    self.init(
      directory: url.appendingPathComponent("SharedResults"), fileProtection: fileProtection)
  }

  /// 保存先のディレクトリを指定して初期化する（テストでは一時ディレクトリを渡す）
  public init(
    directory: URL,
    fileProtection: SharedResultFileProtection = .completeUntilFirstUserAuthentication
  ) {
    self.directory = directory
    self.fileProtection = fileProtection
  }

  /// 結果を保存する。保存済みの `revision` が `expectedRevision` と一致し、
  /// 保存する結果の `revision` がそれより進んでいるときだけ書き込む（比較交換）。
  ///
  /// 照合と書き込みの間は、プロセス間で共有するファイルロックで排他にする。
  /// - Parameters:
  ///   - result: 保存する結果
  ///   - expectedRevision: 読み込んだときの `revision`。新しく作る結果なら `nil`（保存済みの結果がないこと）
  /// - Throws: 保存済みの結果が別の `revision` のとき、または保存する結果の `revision` が
  ///   `expectedRevision` より進んでいないとき `SharedResultStoreError.revisionConflict`。
  ///   端末のロック中などで読み書きできなければ `SharedResultStoreError.fileAccessDenied`
  public func save(_ result: SharedResult, expectedRevision: UInt64?) throws {
    let url = fileURL(for: result.sessionID)
    try withFileLock(for: result.sessionID) {
      let storedRevision = try read(from: url)?.revision
      // 古い結果を新しい revision の前提で渡されても、状態を巻き戻さない
      guard storedRevision == expectedRevision,
        expectedRevision.map({ result.revision > $0 }) ?? true
      else {
        throw SharedResultStoreError.revisionConflict
      }
      try write(result, to: url)
    }
  }

  /// 結果を読み込む（存在しなければ nil）。別プロセスの更新を反映するため、毎回ファイルから読む
  /// - Throws: 端末のロック中などで読めなければ `SharedResultStoreError.fileAccessDenied`
  public func load(sessionID: SessionID) throws -> SharedResult? {
    try read(from: fileURL(for: sessionID))
  }

  /// 結果を削除
  public func delete(sessionID: SessionID) throws {
    try withFileLock(for: sessionID) {
      try removeFile(at: fileURL(for: sessionID))
    }
  }

  /// 不要になった結果を整理し、中断された挿入を復旧する（iOS-IPC-05, iOS-IPC-06）。
  ///
  /// 本体アプリの起動時やキーボードの表示時に呼ぶ。端末の再起動・拡張の強制終了・本体アプリの中断の後でも、
  /// 状態が矛盾せず、自動で再挿入されない状態にそろえる。
  /// - 挿入済みの結果と、有効期限を過ぎた結果は削除する（共有テキストを残さない）
  /// - 猶予時間を過ぎても挿入中のままの結果は `insertionUnknown` にする。利用者の確認なしには再挿入できない
  /// - 読み込めない（壊れた）結果は、挿入に使えないため削除する
  /// - 端末のロック中などで読み書きできない結果は、変更せずに残す
  /// - 端末の時刻が作成時より前の結果は、期限を判定できないため削除しない
  @discardableResult
  public func cleanUp(at now: Date) throws -> SharedResultCleanUpReport {
    var report = SharedResultCleanUpReport()
    for sessionID in try storedSessionIDs() {
      let url = fileURL(for: sessionID)
      do {
        try withFileLock(for: sessionID) {
          let stored: SharedResult?
          do {
            stored = try read(from: url)
          } catch is DecodingError {
            try removeFile(at: url)
            report.removedCount += 1
            return
          }
          guard var result = stored else { return }
          if result.consumedAt != nil || (now >= result.createdAt && now >= result.expiresAt) {
            try removeFile(at: url)
            report.removedCount += 1
          } else if case .inserting = result.status,
            result.insertability(for: sessionID, at: now) == .needsConfirmation
          {
            try result.markInsertionUnknown()
            try write(result, to: url)
            report.markedInsertionUnknownCount += 1
          }
        }
      } catch SharedResultStoreError.fileAccessDenied {
        report.skippedCount += 1
      }
    }
    return report
  }

  /// 保存されている結果のセッションID。ディレクトリがなければ空
  private func storedSessionIDs() throws -> [SessionID] {
    let names: [String]
    do {
      names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      return []
    }
    return names.compactMap { name in
      guard name.hasSuffix(".json"), let uuid = UUID(uuidString: String(name.dropLast(5))) else {
        return nil
      }
      return SessionID(rawValue: uuid)
    }
  }

  /// 存在確認の後に別プロセスが削除する競合を避けるため、先に読み込み、ファイルがないときだけ `nil` にする
  private func read(from url: URL) throws -> SharedResult? {
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      return nil
    } catch let error as CocoaError where error.code == .fileReadNoPermission {
      throw SharedResultStoreError.fileAccessDenied
    }
    return try JSONDecoder().decode(SharedResult.self, from: data)
  }

  private func write(_ result: SharedResult, to url: URL) throws {
    let data = try JSONEncoder().encode(result)
    do {
      try data.write(to: url, options: [.atomic, fileProtection.writingOption])
    } catch let error as CocoaError where error.code == .fileWriteNoPermission {
      throw SharedResultStoreError.fileAccessDenied
    }
  }

  private func removeFile(at url: URL) throws {
    do {
      try FileManager.default.removeItem(at: url)
    } catch let error as CocoaError where error.code == .fileNoSuchFile {
      return
    }
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

/// 共有結果のファイルに付ける保護クラス（iOS-IPC-05）。
///
/// 保護の強いクラスほど、端末のロック中に読み書きできない期間が長い。
/// 読み書きできないときは `SharedResultStoreError.fileAccessDenied` になる。
public enum SharedResultFileProtection: Hashable, Sendable {
  /// ロック中は読み書きできない
  case complete
  /// ロック中は新しく開けないが、開いているファイルには書ける
  case completeUnlessOpen
  /// 再起動後、最初にロックを解除するまで読み書きできない（OS の既定）
  case completeUntilFirstUserAuthentication
  /// 保護しない
  case none

  var writingOption: Data.WritingOptions {
    switch self {
    case .complete: .completeFileProtection
    case .completeUnlessOpen: .completeFileProtectionUnlessOpen
    case .completeUntilFirstUserAuthentication: .completeFileProtectionUntilFirstUserAuthentication
    case .none: .noFileProtection
    }
  }
}

/// `SharedResultStore.cleanUp(at:)` の結果
public struct SharedResultCleanUpReport: Hashable, Sendable {
  /// 削除した結果の数（挿入済み・期限切れ・読み込めない）
  public var removedCount = 0
  /// 挿入中のまま中断していたため、挿入結果不明にした数
  public var markedInsertionUnknownCount = 0
  /// 端末のロック中などで読み書きできず、変更しなかった数
  public var skippedCount = 0

  public init(removedCount: Int = 0, markedInsertionUnknownCount: Int = 0, skippedCount: Int = 0) {
    self.removedCount = removedCount
    self.markedInsertionUnknownCount = markedInsertionUnknownCount
    self.skippedCount = skippedCount
  }
}

public enum SharedResultStoreError: Error, Hashable, Sendable {
  /// 読み込んだ後に別のプロセスが結果を更新した。読み込み直してから状態を変える
  case revisionConflict
  /// プロセス間の排他ロックを取れなかった
  case lockFailed
  /// 端末のロック中（ファイル保護）やアクセス権限のため、結果を読み書きできない
  case fileAccessDenied
}
