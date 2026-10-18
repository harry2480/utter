import Foundation
import GRDB
import UtterCore

/// 入力履歴の保存層（7章, AC-12）。
///
/// 入力履歴は初期無効のオプトインで、設定（`AppSettings.historyEnabled`）が有効で、かつ保存の直前の入力先が
/// 機密入力でない（`SensitiveInputDecision.allowsHistory`）ときだけ保存する。どちらも省略できないよう、
/// `record` の引数に既定値を持たせない。1つのセッションにつき1件で、同じセッションを保存し直すと置き換える。
///
/// 履歴を無効にするときは、設定を先に無効にしてから `removeAll()` を呼ぶ。`record` は設定を書き込みの中で読むため、
/// 無効にする前に始まった保存も、`removeAll()` より後に書き込まれることはない。
/// 削除した本文がデータベースのファイルに残らないよう、`UtterDatabase` は削除した領域を上書きする設定で開く。
public struct InputHistoryStore: Sendable {
  private let database: UtterDatabase

  public init(database: UtterDatabase) {
    self.database = database
  }

  /// 挿入した本文を履歴に保存する。保存しなかった理由を返し、保存したら `nil` を返す。
  ///
  /// - Parameters:
  ///   - historyEnabled: 設定で履歴が有効か。無効化との順序を保つため、書き込みの中で最新の設定を読む
  ///   - sensitivity: 保存の直前に、その時点の入力先で判定し直した結果
  @discardableResult
  public func record(
    _ text: String,
    session: SessionID,
    at date: Date,
    historyEnabled: @Sendable () -> Bool,
    sensitivity: SensitiveInputDecision
  ) throws -> InputHistorySkipReason? {
    guard sensitivity.allowsHistory else { return .sensitiveInput }
    guard !text.allSatisfy(\.isWhitespace) else { return .emptyText }
    return try database.writer.write { db in
      guard historyEnabled() else { return .disabled }
      // 保存し直したセッションを新しい順の先頭にするため、行を作り直す
      try db.execute(
        sql: "INSERT OR REPLACE INTO inputHistory (sessionID, text, createdAt) VALUES (?, ?, ?)",
        arguments: [session.rawValue.uuidString, text, date.timeIntervalSince1970])
      return nil
    }
  }

  /// 新しい順の履歴。`limit` を渡すとその件数までにする
  public func entries(limit: Int? = nil) throws -> [InputHistoryEntry] {
    try database.writer.read { db in
      try Row.fetchAll(
        db,
        sql: "SELECT sessionID, text, createdAt FROM inputHistory ORDER BY createdAt DESC, id DESC"
          + " LIMIT ?",
        arguments: [limit.map { max(0, $0) } ?? -1]
      ).compactMap { row in
        guard let uuid = UUID(uuidString: row["sessionID"]) else { return nil }
        return InputHistoryEntry(
          sessionID: SessionID(rawValue: uuid), text: row["text"],
          createdAt: Date(timeIntervalSince1970: row["createdAt"]))
      }
    }
  }

  /// セッションの履歴を削除する。なければ何もしない
  public func remove(session: SessionID) throws {
    try database.writer.write { db in
      try db.execute(
        sql: "DELETE FROM inputHistory WHERE sessionID = ?",
        arguments: [session.rawValue.uuidString])
    }
  }

  /// 履歴をすべて削除する。履歴を無効にしたとき、利用者が消去を選んだときに使う
  public func removeAll() throws {
    try database.writer.write { db in
      try db.execute(sql: "DELETE FROM inputHistory")
    }
  }
}

/// 保存した入力履歴。
public struct InputHistoryEntry: Hashable, Sendable {
  public let sessionID: SessionID
  public let text: String
  public let createdAt: Date

  public init(sessionID: SessionID, text: String, createdAt: Date) {
    self.sessionID = sessionID
    self.text = text
    self.createdAt = createdAt
  }
}

// 本文をログに出さないよう、文字列表現とリフレクションには作成時刻と文字数だけを出す。
extension InputHistoryEntry: CustomStringConvertible, CustomReflectable {
  public var description: String {
    "InputHistoryEntry(createdAt: \(createdAt.timeIntervalSince1970), length: \(text.count))"
  }

  public var customMirror: Mirror {
    Mirror(self, children: ["createdAt": createdAt, "length": text.count])
  }
}

/// 履歴に保存しなかった理由。
public enum InputHistorySkipReason: Hashable, Sendable {
  /// 設定で履歴が無効（既定）
  case disabled
  /// 入力先が機密入力、または判定できない
  case sensitiveInput
  /// 本文が空
  case emptyText
}
