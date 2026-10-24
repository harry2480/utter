import Foundation

/// Edit Mode（AC-14, v1.1）を有効にするかの切り替え。MVP 外の先行実装のため既定で無効。
///
/// `AppSettings` に項目を足すまでの間、UserDefaults の明示キーで切り替える。起動引数
/// `-UtterEditModeEnabled YES` でも有効にできる（引数は UserDefaults の引数ドメインに入る）。
/// 無効の間はメニューにも出さず、選択範囲の読み取りも送信も行わない。
enum EditModeFeature {
  static let defaultsKey = "UtterEditModeEnabled"

  /// 明示的に真（`true` / `YES` / `1`）を設定した場合だけ有効。未設定・それ以外の値は無効
  static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
    defaults.bool(forKey: defaultsKey)
  }
}
