/// 本体アプリ（macOS）が OS に求める権限（PERM-01）。iOS 本体アプリの権限は `HostAppPermission` で表す。
///
/// 宣言の順（`allCases`）が要求する順になる。録音に要るマイクを最初にし、使う流れ（録音 → 認識 → 挿入）に沿って並べ、
/// 修飾キー単独のショートカットなど任意の機能でだけ要る入力監視を最後にする。
public enum AppPermission: Hashable, Sendable, CaseIterable {
  /// マイク（録音）
  case microphone
  /// 音声認識（使う STT が要求する場合）
  case speechRecognition
  /// Accessibility（入力欄の取得・挿入など）
  case accessibility
  /// 入力監視（修飾キー単独のショートカットなどで要る場合）
  case inputMonitoring
}

/// 権限の状態。Apps のアダプターが OS の状態から作る。
///
/// Accessibility のように OS が「未確認」と「拒否」を区別しない権限は、アプリが一度も要求していなければ `notDetermined`、
/// 要求した後に許可されていなければ `denied` とする。
public enum PermissionStatus: Hashable, Sendable {
  /// まだ要求していない
  case notDetermined
  case granted
  /// 拒否されている（後から取り消された場合を含む）。利用者がシステム設定で許可し直せる
  case denied
  /// MDM・ペアレンタルコントロールなどで制限され、利用者には変えられない
  case restricted
}

/// ある時点の権限の状態（PERM-02）。含まない権限は `notDetermined` とみなす。
public struct PermissionSnapshot: Hashable, Sendable {
  public var statuses: [AppPermission: PermissionStatus]

  public init(_ statuses: [AppPermission: PermissionStatus] = [:]) {
    self.statuses = statuses
  }

  public func status(of permission: AppPermission) -> PermissionStatus {
    statuses[permission] ?? .notDetermined
  }

  public func isGranted(_ permission: AppPermission) -> Bool {
    status(of: permission) == .granted
  }

  /// `previous` の時点で許可されていて、今は許可されていない権限（PERM-02）。
  ///
  /// 拒否・制限に変わった場合に加え、OS 側で設定が消されて `notDetermined` に戻った場合も取り消しとみなす。
  public func revokedPermissions(since previous: PermissionSnapshot) -> Set<AppPermission> {
    Set(AppPermission.allCases.filter { previous.isGranted($0) && !isGranted($0) })
  }
}
