import UtterCore

/// OS の権限の状態の取得と要求（PERM-01, PERM-02）。
///
/// 状態の取得では OS のダイアログを出さない。要求とシステム設定を開く操作は、利用者のボタン操作からだけ呼ぶ。
@MainActor
protocol PermissionAccess {
  /// 現在の権限の状態。OS のダイアログは出さない
  func currentSnapshot() -> PermissionSnapshot
  /// OS の許可ダイアログで要求する
  func request(_ permission: AppPermission) async
  /// システム設定のその権限の画面を開く
  func openSystemSettings(for permission: AppPermission)
}
