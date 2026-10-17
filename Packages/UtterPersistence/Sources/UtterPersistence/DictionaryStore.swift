import GRDB

/// ユーザー辞書の保存層（TXT-03）。
///
/// 辞書語と用語置換ルールを保存する。読み出した値から UtterText の `UserDictionary` を組み立てるのは呼び出し側の責務で、
/// ルール同士の競合の検証もそこで行う。UtterText に依存しないよう、ここでは文字列として扱う。
public struct DictionaryStore: Sendable {
  private let database: UtterDatabase

  public init(database: UtterDatabase) {
    self.database = database
  }

  /// 追加した順の辞書語
  public func terms() throws -> [String] {
    try database.writer.read { db in
      try String.fetchAll(db, sql: "SELECT spelling FROM dictionaryTerm ORDER BY id")
    }
  }

  /// 辞書語を追加する。すでにあれば何もしない
  public func addTerm(_ spelling: String) throws {
    guard !spelling.isEmpty else { throw DictionaryStoreError.emptySpelling }
    try database.writer.write { db in
      try db.execute(
        sql: "INSERT INTO dictionaryTerm (spelling) VALUES (?) ON CONFLICT(spelling) DO NOTHING",
        arguments: [spelling])
    }
  }

  /// 辞書語を削除する。なければ何もしない
  public func removeTerm(_ spelling: String) throws {
    try database.writer.write { db in
      try db.execute(sql: "DELETE FROM dictionaryTerm WHERE spelling = ?", arguments: [spelling])
    }
  }

  /// 定義順の置換ルール
  public func rules() throws -> [StoredReplacementRule] {
    try database.writer.read { db in
      try Row.fetchAll(
        db, sql: "SELECT pattern, replacement, ignoresCase FROM replacementRule ORDER BY id"
      ).map { row in
        StoredReplacementRule(
          pattern: row["pattern"], replacement: row["replacement"], ignoresCase: row["ignoresCase"])
      }
    }
  }

  /// 置換ルールを追加する。同じパターンのルールがあれば、定義順を保ったまま置換後の表記と大文字小文字の扱いを更新する
  public func saveRule(_ rule: StoredReplacementRule) throws {
    guard !rule.pattern.isEmpty else { throw DictionaryStoreError.emptyPattern }
    try database.writer.write { db in
      try db.execute(
        sql: """
          INSERT INTO replacementRule (pattern, replacement, ignoresCase) VALUES (?, ?, ?)
          ON CONFLICT(pattern) DO UPDATE SET
            replacement = excluded.replacement, ignoresCase = excluded.ignoresCase
          """,
        arguments: [rule.pattern, rule.replacement, rule.ignoresCase])
    }
  }

  /// パターンが一致する置換ルールを削除する。なければ何もしない
  public func removeRule(pattern: String) throws {
    try database.writer.write { db in
      try db.execute(sql: "DELETE FROM replacementRule WHERE pattern = ?", arguments: [pattern])
    }
  }

  /// 辞書語と置換ルールをすべて削除する
  public func removeAll() throws {
    try database.writer.write { db in
      try db.execute(sql: "DELETE FROM dictionaryTerm")
      try db.execute(sql: "DELETE FROM replacementRule")
    }
  }
}

/// 保存された用語置換ルール（TXT-03）。UtterText の `ReplacementRule` と同じ項目を持つ
public struct StoredReplacementRule: Hashable, Sendable {
  public let pattern: String
  public let replacement: String
  public let ignoresCase: Bool

  public init(pattern: String, replacement: String, ignoresCase: Bool = false) {
    self.pattern = pattern
    self.replacement = replacement
    self.ignoresCase = ignoresCase
  }
}

/// 辞書の保存エラー。利用者の入力は含めない
public enum DictionaryStoreError: Error, Hashable, Sendable {
  case emptySpelling
  case emptyPattern
}
