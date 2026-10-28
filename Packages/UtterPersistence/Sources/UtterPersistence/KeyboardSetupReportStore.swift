import Foundation
import UtterCore

/// キーボード拡張が表示されたこととフルアクセスの有無（`KeyboardSetupReport`）を App Group に残し、本体アプリのセットアップ画面が読む（#200）。
///
/// キーボード拡張が表示されるたびに `save(_:)` で残し直し、本体アプリは画面を出すときに `load()` で読む。
/// フルアクセスがないとキーボード拡張は App Group に書けない場合があり、そのときは報告が届かない（本体アプリは手動の「済んだ」で扱う）。
/// 1つのファイルを丸ごと書き換えるだけのため、比較交換はせず、書き込みはアトミックに行う。
/// 入力した文字・本文・秘密情報は持たない（iOS-IPC-04, iAC-08）。
public actor KeyboardSetupReportStore {
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
      directory: url.appendingPathComponent("KeyboardSetupReport"), fileProtection: fileProtection)
  }

  /// 保存先のディレクトリを指定して初期化する（テストでは一時ディレクトリを渡す）
  public init(
    directory: URL,
    fileProtection: SharedResultFileProtection = .completeUntilFirstUserAuthentication
  ) {
    self.fileURL = directory.appendingPathComponent("report.json")
    self.fileProtection = fileProtection
  }

  /// 報告を残す。前の報告は置き換える
  /// - Throws: 端末のロック中・フルアクセスなしなどで書けなければ `SharedResultStoreError.fileAccessDenied`
  public func save(_ report: KeyboardSetupReport) throws {
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try JSONEncoder().encode(report)
    do {
      try data.write(to: fileURL, options: [.atomic, fileProtection.writingOption])
    } catch let error as CocoaError where error.code == .fileWriteNoPermission {
      throw SharedResultStoreError.fileAccessDenied
    }
  }

  /// 残っている報告を読む。残っていなければ `nil`
  /// - Throws: 読めなければ `SharedResultStoreError.fileAccessDenied`、復号できなければ
  ///   `SharedResultStoreError.corruptedResult`
  public func load() throws -> KeyboardSetupReport? {
    let data: Data
    do {
      data = try Data(contentsOf: fileURL)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      return nil
    } catch let error as CocoaError where error.code == .fileReadNoPermission {
      throw SharedResultStoreError.fileAccessDenied
    }
    guard let report = try? JSONDecoder().decode(KeyboardSetupReport.self, from: data) else {
      throw SharedResultStoreError.corruptedResult
    }
    return report
  }
}
