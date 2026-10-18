import Foundation

/// アプリケーション設定を `UserDefaults` に保存・復元する（2.1節, 2.3節, 5章, 7章）。
///
/// 保存先の `UserDefaults` は注入する（テストは専用の suite を渡す）。`UserDefaults` は `Sendable` でないため、
/// この型も `Sendable` にしない。アプリ側で1つの隔離領域（`@MainActor` など）から使う。
/// 秘密情報は扱わない（Keychain の責務）。App Group の共有領域を渡す場合も、ここに秘密情報は入らない。
public struct AppSettingsStore {
  /// 設定を保存するキー
  public static let key = "utter.appSettings"

  private let defaults: UserDefaults

  public init(defaults: UserDefaults) {
    self.defaults = defaults
  }

  /// 保存済みの設定。未保存・壊れた値・未知の版なら既定値（同意はすべて未同意）を返す
  public func load() -> AppSettings {
    guard let data = defaults.data(forKey: Self.key),
      let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
    else {
      return AppSettings()
    }
    return settings
  }

  /// 設定を保存する
  public func save(_ settings: AppSettings) throws {
    defaults.set(try JSONEncoder().encode(settings), forKey: Self.key)
  }

  /// 保存済みの設定を消し、次の `load()` で既定値に戻す
  public func reset() {
    defaults.removeObject(forKey: Self.key)
  }
}
