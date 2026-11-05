import Foundation
import UtterPersistence

/// 待機セッションの設定（iOS-04・iOS-05）。端末内の `UserDefaults` に置き、App Group には置かない。
/// 挿入のしかたはキーボードが従うため、本体アプリが状態に載せて知らせる（`StandbyHostState.insertionMode`）。
public struct StandbyPreferences {
  /// 無操作で待機を終えるまでの選択肢（分）。無期限にはしない（iOS-04, iOS-PERF-03: バックグラウンドの audio は、無操作で終わる待機のためにだけ使う）
  public static let idleTimeoutChoices: [Int] = [1, 5, 15, 30]
  public static let defaultIdleTimeoutMinutes = 5

  private static let insertionModeKey = "standby.insertionMode"
  private static let idleTimeoutKey = "standby.idleTimeoutMinutes"
  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// 停止後の挿入のしかた。既定は自動挿入
  public var insertionMode: StandbyInsertionMode {
    get {
      defaults.string(forKey: Self.insertionModeKey).flatMap(StandbyInsertionMode.init)
        ?? .automatic
    }
    nonmutating set { defaults.set(newValue.rawValue, forKey: Self.insertionModeKey) }
  }

  /// 無操作で待機を終えるまでの分。選択肢にない値（以前の「終えない」を含む）は既定に戻す
  public var idleTimeoutMinutes: Int {
    get {
      let stored = defaults.integer(forKey: Self.idleTimeoutKey)
      return Self.idleTimeoutChoices.contains(stored) ? stored : Self.defaultIdleTimeoutMinutes
    }
    nonmutating set { defaults.set(newValue, forKey: Self.idleTimeoutKey) }
  }

  /// 状態機械に渡す設定
  public var sessionConfiguration: StandbySessionConfiguration {
    StandbySessionConfiguration(idleTimeout: .seconds(idleTimeoutMinutes * 60))
  }
}
