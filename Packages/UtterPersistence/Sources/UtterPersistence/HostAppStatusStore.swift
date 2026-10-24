import Foundation
import UtterCore

/// 本体アプリの状態（権限・STT モデル・整形設定と観測時刻）を App Group に残し、キーボード拡張が読む（iAC-07）。
///
/// 本体アプリが前面に来たときなどに `save(_:)` で残し直し、キーボード拡張は表示時に `load()` で読む。
/// 鮮度の判定は `KeyboardAvailability` が観測時刻で行う。秘密情報・本文は持たない（`HostAppStatus`）。
/// 1つのファイルを丸ごと書き換えるだけのため、比較交換はせず、書き込みはアトミックに行う。
public actor HostAppStatusStore {
  private let fileURL: URL
  private let fileProtection: SharedResultFileProtection

  /// App Group 経由のディレクトリを使用して初期化する。コンテナを取得できなければ `nil`
  /// - Parameters:
  ///   - groupIdentifier: App Group 識別子
  ///   - fileProtection: ファイルに付ける保護クラス
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
      directory: url.appendingPathComponent("HostAppStatus"), fileProtection: fileProtection)
  }

  /// 保存先のディレクトリを指定して初期化する（テストでは一時ディレクトリを渡す）
  public init(
    directory: URL,
    fileProtection: SharedResultFileProtection = .completeUntilFirstUserAuthentication
  ) {
    self.fileURL = directory.appendingPathComponent("status.json")
    self.fileProtection = fileProtection
  }

  /// 状態を残す。前の状態は置き換える
  /// - Throws: 端末のロック中などで書けなければ `SharedResultStoreError.fileAccessDenied`
  public func save(_ status: HostAppStatus) throws {
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try JSONEncoder().encode(status)
    do {
      try data.write(to: fileURL, options: [.atomic, fileProtection.writingOption])
    } catch let error as CocoaError where error.code == .fileWriteNoPermission {
      throw SharedResultStoreError.fileAccessDenied
    }
  }

  /// 残っている状態を読む。残っていなければ `nil`
  /// - Throws: 読めなければ `SharedResultStoreError.fileAccessDenied`、復号できなければ
  ///   `SharedResultStoreError.corruptedResult`
  public func load() throws -> HostAppStatus? {
    let data: Data
    do {
      data = try Data(contentsOf: fileURL)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      return nil
    } catch let error as CocoaError where error.code == .fileReadNoPermission {
      throw SharedResultStoreError.fileAccessDenied
    }
    guard let status = try? JSONDecoder().decode(HostAppStatus.self, from: data) else {
      throw SharedResultStoreError.corruptedResult
    }
    return status
  }

  /// 残っている状態を削除する（本体アプリの状態を案内に使わせない）
  public func delete() throws {
    do {
      try FileManager.default.removeItem(at: fileURL)
    } catch let error as CocoaError where error.code == .fileNoSuchFile {
      return
    } catch let error as CocoaError where error.code == .fileWriteNoPermission {
      throw SharedResultStoreError.fileAccessDenied
    }
  }
}
