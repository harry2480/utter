/// 権限の状態から決まる、使える機能と案内（PERM-01, PERM-02）。
///
/// 権限が足りない機能だけを無効にし、ほかの機能は使えるままにする。挿入は `permittedRoutes` を
/// `InsertionPolicy.plan(app:verification:permittedRoutes:)` に渡し、使えない経路を飛ばす。
/// 経路がすべて使えなくても、コピー可能なプレビューへの退避（`InsertionPreviewReason.noAvailableRoute`）は残る。
public struct FeatureAvailability: Hashable, Sendable {
  /// 使える機能
  public let availableFeatures: Set<AppFeature>
  /// 無効にした機能と、その理由
  public let unavailableFeatures: [AppFeature: FeatureUnavailableReason]
  /// 足りない権限ごとの案内。要求する順（`AppPermission.allCases` の順）
  public let notices: [PermissionNotice]

  /// - Parameters:
  ///   - features: 利用者が有効にしている機能（使う挿入経路・ショートカットの種類を含む）
  ///   - permissions: 現在の権限の状態
  ///   - requirements: 機能ごとに要る権限
  ///   - previous: 前回観測した権限の状態。渡すと、許可から変わった権限の案内を取り消しとして示す（PERM-02）
  public init(
    features: Set<AppFeature>,
    permissions: PermissionSnapshot,
    requirements: PermissionRequirements,
    previous: PermissionSnapshot? = nil
  ) {
    var available: Set<AppFeature> = []
    var unavailable: [AppFeature: FeatureUnavailableReason] = [:]
    for feature in features {
      guard let required = requirements.permissions(for: feature) else {
        unavailable[feature] = .unknownRequirements
        continue
      }
      let missing = required.filter { !permissions.isGranted($0) }
      if missing.isEmpty {
        available.insert(feature)
      } else {
        unavailable[feature] = .missingPermissions(missing)
      }
    }

    let revoked = previous.map(permissions.revokedPermissions(since:)) ?? []
    notices = AppPermission.allCases.compactMap { permission in
      let disabled = PermissionRequirements.features(
        requiring: permission, among: Set(unavailable.keys),
        permissions: { unavailable[$0]?.missingPermissions })
      guard !disabled.isEmpty else { return nil }
      return PermissionNotice(
        permission: permission,
        disabledFeatures: disabled,
        wasRevoked: revoked.contains(permission),
        action: PermissionAction(permissions.status(of: permission)))
    }
    availableFeatures = available
    unavailableFeatures = unavailable
  }

  /// 録音を始められるか（REC-04）。マイクと、使う STT が要する権限がそろうときだけ `true`
  public var canStartRecording: Bool {
    availableFeatures.contains(.recording)
  }

  /// 権限があり使える挿入経路。`InsertionPolicy.plan` の `permittedRoutes` に渡す
  public var permittedRoutes: Set<InsertionRoute> {
    Set(
      availableFeatures.compactMap {
        if case .insertion(let route) = $0 { route } else { nil }
      })
  }
}

/// 機能を無効にした理由。
public enum FeatureUnavailableReason: Hashable, Sendable {
  /// 許可されていない権限がある
  case missingPermissions(Set<AppPermission>)
  /// 要る権限が分からない（`PermissionRequirements.insertionRoutes` にない経路）。安全側に倒して使わない
  case unknownRequirements

  public var missingPermissions: Set<AppPermission> {
    if case .missingPermissions(let permissions) = self { permissions } else { [] }
  }
}

/// 足りない権限の案内（PERM-02）。
public struct PermissionNotice: Hashable, Sendable {
  public let permission: AppPermission
  /// この権限がないために無効にした機能
  public let disabledFeatures: Set<AppFeature>
  /// 前回は許可されていた（後から取り消された）
  public let wasRevoked: Bool
  /// 再設定の方法
  public let action: PermissionAction

  public init(
    permission: AppPermission, disabledFeatures: Set<AppFeature>, wasRevoked: Bool,
    action: PermissionAction
  ) {
    self.permission = permission
    self.disabledFeatures = disabledFeatures
    self.wasRevoked = wasRevoked
    self.action = action
  }
}
