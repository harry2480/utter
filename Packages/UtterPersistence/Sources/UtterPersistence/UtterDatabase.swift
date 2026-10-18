import Foundation
import GRDB

/// 辞書・使用量・任意の入力履歴を保存する SQLite データベース（3章, TXT-03, AI-05, 7章）。
///
/// 開くたびにスキーマ移行（マイグレーション）を適用する。テストは `inMemory()` を使う。
/// 読み書きは同期的にディスクへアクセスするため、メインスレッド以外から呼ぶ。
public struct UtterDatabase: Sendable {
  let writer: any DatabaseWriter

  /// `url` のファイルを開く（なければ作る）
  public static func open(at url: URL) throws -> UtterDatabase {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    // 同じファイルを別のインスタンスやプロセスが開いていても、書き込みのロックをしばらく待つ
    var configuration = Configuration()
    configuration.busyMode = .timeout(5)
    return try UtterDatabase(writer: DatabaseQueue(path: url.path, configuration: configuration))
  }

  /// メモリ上のデータベースを開く。閉じると内容は消える
  public static func inMemory() throws -> UtterDatabase {
    try UtterDatabase(writer: DatabaseQueue())
  }

  private init(writer: any DatabaseWriter) throws {
    try Self.migrator.migrate(writer)
    self.writer = writer
  }

  /// 版ごとのスキーマ移行。登録済みの移行は変更せず、新しい版を追加する
  static var migrator: DatabaseMigrator {
    var migrator = DatabaseMigrator()
    migrator.registerMigration("v1") { db in
      try db.create(table: "dictionaryTerm") { table in
        table.autoIncrementedPrimaryKey("id")
        table.column("spelling", .text).notNull().unique()
      }
      try db.create(table: "replacementRule") { table in
        table.autoIncrementedPrimaryKey("id")
        table.column("pattern", .text).notNull().unique()
        table.column("replacement", .text).notNull()
        table.column("ignoresCase", .boolean).notNull()
      }
      // 金額は Decimal の誤差を避けるため文字列で持つ
      try db.create(table: "monthlyUsage") { table in
        table.column("monthIndex", .integer).notNull()
        table.column("currencyCode", .text).notNull()
        table.column("amount", .text).notNull()
        table.primaryKey(["monthIndex", "currencyCode"])
      }
    }
    // 入力履歴（7章, AC-12）。初期無効で、有効にした利用者だけが使う
    migrator.registerMigration("v2") { db in
      try db.create(table: "inputHistory") { table in
        table.autoIncrementedPrimaryKey("id")
        table.column("sessionID", .text).notNull().unique()
        table.column("text", .text).notNull()
        table.column("createdAt", .double).notNull().indexed()
      }
    }
    return migrator
  }
}
