import Foundation
import UtterCore

/// ユーザー辞書の保存層（TXT-03）。
/// 
/// UtterText の UserDictionary を永続化するメモリベースのストア。
public actor DictionaryStore: Sendable {
  private var entries: [String: String] = [:]

  public init() {}

  /// エントリを追加または更新
  public func set(_ key: String, _ value: String) {
    entries[key] = value
  }

  /// エントリを取得
  public func get(_ key: String) -> String? {
    entries[key]
  }

  /// エントリを削除
  public func remove(_ key: String) {
    entries.removeValue(forKey: key)
  }

  /// すべてのエントリを取得
  public func all() -> [String: String] {
    entries
  }

  /// すべてクリア
  public func clear() {
    entries.removeAll()
  }
}

/// 月次推定費用の保存層（AI-05）。
/// 
/// MonthlyUsageLedger を永続化するメモリベースのストア。
public struct MonthlyUsageStore: Sendable {
  private var ledger: [String: Double] = [:]

  public init() {}

  /// 月のコスト合計を記録
  mutating func record(month: String, cost: Double) {
    ledger[month] = (ledger[month] ?? 0) + cost
  }

  /// 月のコスト合計を取得
  func total(month: String) -> Double {
    ledger[month] ?? 0
  }

  /// すべての月のコストを取得
  func all() -> [String: Double] {
    ledger
  }
}
