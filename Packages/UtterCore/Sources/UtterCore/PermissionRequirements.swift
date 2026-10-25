/// 権限によって使えるかが変わる機能（PERM-01, PERM-02）。
public enum AppFeature: Hashable, Sendable {
  /// 録音と音声認識（REC-01）。マイクと、使う STT が要する権限が要る。
  ///
  /// 認識できない録音で発話を失わないため、音声認識を録音と別の機能に分けない。
  case recording
  /// その経路による自動挿入（INS-02）。macOS の経路（`textDocumentProxy` 以外）を渡す。
  /// コピー可能なプレビューへの退避は権限が要らないため含めない
  case insertion(InsertionRoute)
  /// 修飾キー単独のショートカット（REC-02）。
  ///
  /// 割り当てられるかは環境の対応（`ShortcutCapabilities`）だけで判定する。割り当てた後にこの機能を有効として要る権限を要求し、
  /// 権限がない間はイベントタップを使わず案内する（権限がないことを割当の拒否にしない）
  case modifierOnlyShortcut
  /// セッション中の Esc によるキャンセル（REC-01）
  case escapeCancel
}

/// 機能ごとに要る権限（PERM-01）。
///
/// マイク以外は Phase 0 の結果で決まるため（音声認識は #48、入力監視は #51、挿入経路ごとの権限は #41）、
/// 既定値を持たせず呼び出し側が明示する（`ShortcutCapabilities` と同じ方針）。
public struct PermissionRequirements: Hashable, Sendable {
  /// 使う STT に要る権限（SpeechAnalyzer が音声認識の許可を要するか, #48）。録音のマイクに加えて要る
  public let transcription: Set<AppPermission>
  /// 挿入経路ごとに要る権限（#41）。含まない経路は要る権限が分からないため使わない
  public let insertionRoutes: [InsertionRoute: Set<AppPermission>]
  /// 修飾キー単独のショートカットに要る権限（#51）
  public let modifierOnlyShortcut: Set<AppPermission>
  /// セッション中の Esc の捕捉に要る権限（#51）
  public let escapeCancel: Set<AppPermission>

  public init(
    transcription: Set<AppPermission>,
    insertionRoutes: [InsertionRoute: Set<AppPermission>],
    modifierOnlyShortcut: Set<AppPermission>,
    escapeCancel: Set<AppPermission>
  ) {
    self.transcription = transcription
    self.insertionRoutes = insertionRoutes
    self.modifierOnlyShortcut = modifierOnlyShortcut
    self.escapeCancel = escapeCancel
  }

  /// 機能に要る権限。要る権限が分からない（`insertionRoutes` にない経路の）場合は `nil`
  public func permissions(for feature: AppFeature) -> Set<AppPermission>? {
    switch feature {
    case .recording: transcription.union([.microphone])
    case .insertion(let route): insertionRoutes[route]
    case .modifierOnlyShortcut: modifierOnlyShortcut
    case .escapeCancel: escapeCancel
    }
  }

  /// 有効な機能に要る権限を、要求する順（`AppPermission.allCases` の順）に返す（PERM-01）。
  ///
  /// 使わない機能（`features` にない機能）だけが要する権限は含めない。
  public func requiredPermissions(for features: Set<AppFeature>) -> [AppPermission] {
    let required = features.reduce(into: Set<AppPermission>()) {
      $0.formUnion(permissions(for: $1) ?? [])
    }
    return AppPermission.allCases.filter(required.contains)
  }

  /// まだ許可されていない権限の要求を、用途（それを要する有効な機能）つきで要求する順に返す（PERM-01）。
  ///
  /// 呼び出し側は先頭から1つずつ、その機能を初めて使う時点やオンボーディングの段階で要求する。
  public func requests(
    for features: Set<AppFeature>, current: PermissionSnapshot
  ) -> [PermissionRequest] {
    requiredPermissions(for: features)
      .filter { !current.isGranted($0) }
      .map { permission in
        PermissionRequest(
          permission: permission,
          features: Self.features(requiring: permission, among: features, permissions: permissions),
          action: PermissionAction(current.status(of: permission)))
      }
  }
}

extension PermissionRequirements {
  /// `features` のうち `permission` を要する機能。要求の用途と案内の無効にした機能で同じ求め方を使う
  static func features(
    requiring permission: AppPermission, among features: Set<AppFeature>,
    permissions: (AppFeature) -> Set<AppPermission>?
  ) -> Set<AppFeature> {
    features.filter { permissions($0)?.contains(permission) == true }
  }
}

/// 権限の要求1件（PERM-01）。
public struct PermissionRequest: Hashable, Sendable {
  public let permission: AppPermission
  /// 用途の説明に使う、この権限を要する有効な機能
  public let features: Set<AppFeature>
  public let action: PermissionAction

  public init(permission: AppPermission, features: Set<AppFeature>, action: PermissionAction) {
    self.permission = permission
    self.features = features
    self.action = action
  }
}

/// 権限を得るために利用者に求める操作。
public enum PermissionAction: Hashable, Sendable {
  /// OS の許可ダイアログで要求する（まだ要求していない）
  case requestFromSystem
  /// システム設定で許可してもらう（拒否・取り消し後は OS のダイアログを出し直せないため）
  case openSystemSettings
  /// 利用者には変えられない（制限されている）。管理者による制限であることを示す
  case notChangeableByUser

  init(_ status: PermissionStatus) {
    switch status {
    case .notDetermined, .granted: self = .requestFromSystem
    case .denied: self = .openSystemSettings
    case .restricted: self = .notChangeableByUser
    }
  }
}
