import Foundation
import UtterCore

/// ユーザー辞書の保存層（TXT-03）。
///
/// UtterText の UserDictionary を永続化するスレッドセーフなストア。
public actor DictionaryStore: Sendable {
  private var entries: [String: String] = [:]

  public init() {}

  /// エントリを追加または更新
  public func set(key: String, value: String) {
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
/// MonthlyUsageLedger を永続化するスレッドセーフなストア。
/// 操作は順序を保証する呼び出し側の責務。
public actor MonthlyUsageStore: Sendable {
  private var ledger: [String: Double] = [:]

  public init() {}

  /// 月のコスト合計に加算（正の値のみ）
  /// - Parameters:
  ///   - month: 月（例: "2024-10"）
  ///   - cost: 追加コスト。非有限値（NaN・無限大）と負の値は拒否
  /// - Throws: 加算後の合計が有限でなければ `CostError.nonFiniteTotal`。このとき既存の合計は変えない
  public func add(month: String, cost: Double) throws {
    // NaN は `>= 0` が false になるため、負の値より先に有限性を確認する
    guard cost.isFinite else {
      throw CostError.nonFiniteCost(cost)
    }
    guard cost >= 0 else {
      throw CostError.negativeCost(cost)
    }
    let total = (ledger[month] ?? 0) + cost
    guard total.isFinite else {
      throw CostError.nonFiniteTotal
    }
    ledger[month] = total
  }

  /// 月のコスト合計を取得
  public func total(month: String) -> Double {
    ledger[month] ?? 0
  }

  /// すべての月のコストを取得
  public func all() -> [String: Double] {
    ledger
  }

  /// 月のコストをリセット
  public func remove(month: String) {
    ledger.removeValue(forKey: month)
  }

  /// すべてクリア
  public func clear() {
    ledger.removeAll()
  }
}

/// コスト記録エラー
public enum CostError: Error {
  case negativeCost(Double)
  case nonFiniteCost(Double)
  /// 加算後の月次合計が有限でない
  case nonFiniteTotal
}
