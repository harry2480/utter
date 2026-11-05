import Foundation
import UtterPersistence

/// 待機セッションの設定（iOS-04・iOS-05）。端末内の `UserDefaults` に置き、App Group には置かない。
/// 挿入のしかたはキーボードが従うため、本体アプリが状態に載せて知らせる（`StandbyHostState.insertionMode`）。
public struct StandbyPreferences {
  /// 無操作で待機を終えるまでの選択肢（分）。`nil` は終えない
  public static let idleTimeoutChoices: [Int?] = [1, 5, 15, 30, nil]
  public static let defaultIdleTimeoutMinutes = 5

  private static let insertionModeKey = "standby.insertionMode"
  private static let idleTimeoutKey = "standby.idleTimeoutMinutes"
  /// 「終えない」を保存するための値
  private static let neverValue = 0

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

  /// 無操作で待機を終えるまでの分。`nil` なら終えない。選択肢にない値は既定に戻す
  public var idleTimeoutMinutes: Int? {
    get {
      guard defaults.object(forKey: Self.idleTimeoutKey) != nil else {
        return Self.defaultIdleTimeoutMinutes
      }
      let stored = defaults.integer(forKey: Self.idleTimeoutKey)
      if stored == Self.neverValue { return nil }
      return Self.idleTimeoutChoices.contains(stored) ? stored : Self.defaultIdleTimeoutMinutes
    }
    nonmutating set { defaults.set(newValue ?? Self.neverValue, forKey: Self.idleTimeoutKey) }
  }

  /// 状態機械に渡す設定
  public var sessionConfiguration: StandbySessionConfiguration {
    StandbySessionConfiguration(idleTimeout: idleTimeoutMinutes.map { .seconds($0 * 60) })
  }
}
