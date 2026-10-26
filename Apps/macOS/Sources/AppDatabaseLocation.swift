import Foundation

/// アプリのデータベース（辞書・使用量・任意の入力履歴）の保存場所。
///
/// `~/Library/Application Support/utter/utter.sqlite`。Bundle ID は署名の設定（Local.xcconfig）で変わるため、
/// フォルダ名に使わず固定の名前にする。App Sandbox は使わない（docs/ビルド・配布規約.md）。
enum AppDatabaseLocation {
  static func url() throws -> URL {
    try FileManager.default
      .url(
        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
      )
      .appending(path: "utter", directoryHint: .isDirectory)
      .appending(path: "utter.sqlite", directoryHint: .notDirectory)
  }
}
