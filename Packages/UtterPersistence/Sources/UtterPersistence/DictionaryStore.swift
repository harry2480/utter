import Foundation
import GRDB

/// ユーザー辞書の保存層（TXT-03）。
///
/// 辞書語と用語置換ルールを保存する。読み出した値から UtterText の `UserDictionary` を組み立てるのは呼び出し側の責務で、
/// ルール同士の競合の検証もそこで行う。UtterText に依存しないよう、ここでは文字列として扱う。
///
/// SQLite はバイト単位で比べるため、辞書語とパターンは Unicode の正規化形式（NFC）をそろえて保存・照合する。
public struct DictionaryStore: Sendable {
  private let database: UtterDatabase

  public init(database: UtterDatabase) {
    self.database = database
  }

  /// 追加した順の辞書語
  public func terms() throws -> [String] {
    try database.writer.read(Self.fetchTerms)
  }

  /// 辞書語を追加する。すでにあれば何もしない
  public func addTerm(_ spelling: String) throws {
    guard !spelling.isEmpty else { throw DictionaryStoreError.emptySpelling }
    try database.writer.write { db in
      try db.execute(
        sql: "INSERT INTO dictionaryTerm (spelling) VALUES (?) ON CONFLICT(spelling) DO NOTHING",
        arguments: [spelling.normalized])
    }
  }

  /// 辞書語を削除する。なければ何もしない
  public func removeTerm(_ spelling: String) throws {
    try database.writer.write { db in
      try db.execute(
        sql: "DELETE FROM dictionaryTerm WHERE spelling = ?", arguments: [spelling.normalized])
    }
  }

  /// 定義順の置換ルール
  public func rules() throws -> [StoredReplacementRule] {
    try database.writer.read(Self.fetchRules)
  }

  /// 辞書語と置換ルールを、同じ時点の内容として読み出す（1つの読み取りで行う）
  public func contents() throws -> (terms: [String], rules: [StoredReplacementRule]) {
    try database.writer.read { db in
      (try Self.fetchTerms(db), try Self.fetchRules(db))
    }
  }

  private static func fetchTerms(_ db: Database) throws -> [String] {
    try String.fetchAll(db, sql: "SELECT spelling FROM dictionaryTerm ORDER BY id")
  }

  private static func fetchRules(_ db: Database) throws -> [StoredReplacementRule] {
    try Row.fetchAll(
      db, sql: "SELECT pattern, replacement, ignoresCase FROM replacementRule ORDER BY id"
    ).map { row in
      StoredReplacementRule(
        pattern: row["pattern"], replacement: row["replacement"], ignoresCase: row["ignoresCase"])
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
        arguments: [rule.pattern.normalized, rule.replacement, rule.ignoresCase])
    }
  }

  /// パターンが一致する置換ルールを削除する。なければ何もしない
  public func removeRule(pattern: String) throws {
    try database.writer.write { db in
      try db.execute(
        sql: "DELETE FROM replacementRule WHERE pattern = ?", arguments: [pattern.normalized])
    }
  }

  /// 辞書語と置換ルールを、渡した内容と順序に置き換える（辞書の編集画面の保存, TXT-03）。
  ///
  /// 1つのトランザクションで行い、失敗したら保存済みの内容を変えない。空の辞書語・パターンがあれば何も保存せずに失敗する。
  /// 重複する辞書語は最初のものだけを、同じパターンのルールは最初の位置に最後の内容を残す（`addTerm` / `saveRule` と同じ扱い）
  public func replaceAll(terms: [String], rules: [StoredReplacementRule]) throws {
    if terms.contains(where: \.isEmpty) { throw DictionaryStoreError.emptySpelling }
    if rules.contains(where: \.pattern.isEmpty) { throw DictionaryStoreError.emptyPattern }
    try database.writer.write { db in
      try db.execute(sql: "DELETE FROM dictionaryTerm")
      try db.execute(sql: "DELETE FROM replacementRule")
      for spelling in terms {
        try db.execute(
          sql: "INSERT INTO dictionaryTerm (spelling) VALUES (?) ON CONFLICT(spelling) DO NOTHING",
          arguments: [spelling.normalized])
      }
      for rule in rules {
        try db.execute(
          sql: """
            INSERT INTO replacementRule (pattern, replacement, ignoresCase) VALUES (?, ?, ?)
            ON CONFLICT(pattern) DO UPDATE SET
              replacement = excluded.replacement, ignoresCase = excluded.ignoresCase
            """,
          arguments: [rule.pattern.normalized, rule.replacement, rule.ignoresCase])
      }
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

extension String {
  /// 保存・照合に使う正規化形式（NFC）
  fileprivate var normalized: String { precomposedStringWithCanonicalMapping }
}

/// 辞書の保存エラー。利用者の入力は含めない
public enum DictionaryStoreError: Error, Hashable, Sendable {
  case emptySpelling
  case emptyPattern
}
