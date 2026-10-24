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
      let storedRevision = try read(sessionID: result.sessionID)?.revision
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
    try read(sessionID: sessionID)
  }

  /// 結果を削除
  public func delete(sessionID: SessionID) throws {
    try withFileLock(for: sessionID) {
      try removeFile(at: fileURL(for: sessionID))
    }
  }

  /// 保存されている結果のセッションID（iOS-07 の救済導線で一覧にする）。
  ///
  /// ファイル名が保存時の形（大文字の UUID）でない結果は `load(sessionID:)` で読めないため含めない。
  /// 内容は読まないため、壊れた結果やロック中で読めない結果も含む。
  public func storedSessionIDs() throws -> [SessionID] {
    try storedFiles().compactMap { sessionID, storedURL in
      storedURL.lastPathComponent == fileURL(for: sessionID).lastPathComponent ? sessionID : nil
    }
  }

  /// 不要になった結果を整理し、中断された挿入を復旧する（iOS-IPC-05, iOS-IPC-06）。
  ///
  /// 本体アプリの起動時やキーボードの表示時に呼ぶ。端末の再起動・拡張の強制終了・本体アプリの中断の後でも、
  /// 状態が矛盾せず、自動で再挿入されない状態にそろえる。
  /// - 挿入済みの結果と、有効期限を過ぎた結果は削除する（共有テキストを残さない）
  /// - 猶予時間を過ぎても挿入中のままの結果は `insertionUnknown` にする。利用者の確認なしには再挿入できない
  /// - 復号できない・値が矛盾している（壊れた）結果は、挿入に使えないため削除する
  /// - ファイル名が保存時の形（大文字の UUID）でない結果は、`load(sessionID:)` で読めないため削除する
  /// - 端末のロック中などで読み書きできない結果は、変更せずに残して次の結果へ進む
  /// - 端末の時刻が作成時より前の結果は、期限を判定できないため削除しない
  /// - 1つの結果で失敗しても、残りの結果の整理は続ける
  @discardableResult
  public func cleanUp(at now: Date) throws -> SharedResultCleanUpReport {
    var report = SharedResultCleanUpReport()
    for (sessionID, storedURL) in try storedFiles() {
      let url = fileURL(for: sessionID)
      do {
        try withFileLock(for: sessionID) {
          // 大文字・小文字を区別するファイルシステムでは、作り直した URL では開けない。列挙した URL で削除する
          guard storedURL.lastPathComponent == url.lastPathComponent else {
            try removeFile(at: storedURL)
            report.removedCount += 1
            return
          }
          let stored: SharedResult?
          do {
            stored = try read(sessionID: sessionID)
          } catch SharedResultStoreError.corruptedResult {
            try removeFile(at: url)
            report.removedCount += 1
            return
          }
          guard var result = stored else { return }
          if result.consumedAt != nil || now >= result.expiresAt {
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
      } catch {
        // ロック中・ロックの失敗・その他の I/O エラーは、この結果を変えずに次へ進む
        report.skippedCount += 1
      }
    }
    return report
  }

  /// 保存されている結果のセッションIDと、列挙したファイルの URL。ディレクトリがなければ空
  private func storedFiles() throws -> [(SessionID, URL)] {
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
      return (SessionID(rawValue: uuid), directory.appendingPathComponent(name))
    }
  }

  /// 存在確認の後に別プロセスが削除する競合を避けるため、先に読み込み、ファイルがないときだけ `nil` にする
  private func read(sessionID: SessionID) throws -> SharedResult? {
    let url = fileURL(for: sessionID)
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      return nil
    } catch let error as CocoaError where error.code == .fileReadNoPermission {
      throw SharedResultStoreError.fileAccessDenied
    }
    // 独自の init(from:) が投げるエラーは DecodingError に包まれないため、種類を問わず壊れた結果として扱う。
    // 合成された復号は有効期限と作成時刻の前後を検証しないため、ここで確かめる。
    // ファイル名と中身のセッションが食い違う結果も、照合や復旧に使えないため壊れた結果とする
    guard let result = try? JSONDecoder().decode(SharedResult.self, from: data),
      result.expiresAt > result.createdAt, result.sessionID == sessionID
    else {
      throw SharedResultStoreError.corruptedResult
    }
    return result
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
    } catch let error as CocoaError where error.code == .fileWriteNoPermission {
      throw SharedResultStoreError.fileAccessDenied
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
      // 端末のロック中（ファイル保護）は EPERM / EACCES になる
      throw errno == EPERM || errno == EACCES
        ? SharedResultStoreError.fileAccessDenied : SharedResultStoreError.lockFailed
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
  /// 保存されている結果を復号できない、または値が矛盾している
  case corruptedResult
}
