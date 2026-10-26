/// 権限オンボーディングの画面に出す内容（PERM-01, PERM-02）。
///
/// 有効な機能に要る権限だけを、要求する順（`AppPermission.allCases` の順）に段階として並べる。
/// 利用者は先頭から1つずつ許可する。要求は画面のボタン操作でだけ行い、この型は要求しない。
public struct PermissionOnboarding: Hashable, Sendable {
  /// 有効な機能に要る権限の段階。許可済みの権限も、進み具合を示すため含める
  public let steps: [PermissionOnboardingStep]
  /// 要る権限が分からず段階に出さない機能（判定待ちの挿入経路など）。安全側に倒して使わない
  public let undecidedFeatures: Set<AppFeature>
  /// 同じ入力から求めた、使える機能と案内
  public let availability: FeatureAvailability

  /// - Parameters:
  ///   - features: 利用者が有効にしている機能
  ///   - permissions: 現在の権限の状態
  ///   - requirements: 機能ごとに要る権限
  ///   - previous: これまでに観測した権限の状態（`PermissionHistory.previousSnapshot`）。取り消しの表示に使う（PERM-02）
  public init(
    features: Set<AppFeature>,
    permissions: PermissionSnapshot,
    requirements: PermissionRequirements,
    previous: PermissionSnapshot? = nil
  ) {
    let availability = FeatureAvailability(
      features: features, permissions: permissions, requirements: requirements,
      previous: previous)
    let notices = Dictionary(
      uniqueKeysWithValues: availability.notices.map { ($0.permission, $0) })
    steps = requirements.requiredPermissions(for: features).map { permission in
      let state: PermissionOnboardingStep.State =
        if let notice = notices[permission] {
          .needed(notice.action, wasRevoked: notice.wasRevoked)
        } else {
          .granted
        }
      return PermissionOnboardingStep(
        permission: permission,
        features: PermissionRequirements.features(
          requiring: permission, among: features, permissions: requirements.permissions(for:)),
        state: state)
    }
    undecidedFeatures = Set(
      availability.unavailableFeatures.filter { $0.value == .unknownRequirements }.keys)
    self.availability = availability
  }

  /// 次に操作してもらう段階。許可されておらず、利用者が変えられる最初の段階。なければ `nil`
  public var currentStep: PermissionOnboardingStep? {
    steps.first { step in
      if case .needed(let action, _) = step.state { action != .notChangeableByUser } else { false }
    }
  }

  /// 段階の権限がすべて許可されている
  public var isComplete: Bool {
    steps.allSatisfy { $0.state == .granted }
  }
}

/// オンボーディングの段階1つ（権限1つ）。
public struct PermissionOnboardingStep: Hashable, Sendable {
  public enum State: Hashable, Sendable {
    case granted
    /// 許可されていない。`wasRevoked` は、以前は許可されていた（後から取り消された）こと（PERM-02）
    case needed(PermissionAction, wasRevoked: Bool)
  }

  public let permission: AppPermission
  /// 用途の説明に使う、この権限を要する有効な機能
  public let features: Set<AppFeature>
  public let state: State

  public init(permission: AppPermission, features: Set<AppFeature>, state: State) {
    self.permission = permission
    self.features = features
    self.state = state
  }
}

/// これまでに許可を観測した権限（PERM-02）。
///
/// アプリを再起動した後や、取り消した後の観測を何度挟んでも取り消しを示し続けるため、
/// 直前の観測ではなく「一度でも許可されていた権限」を覚える。許可し直されれば取り消しの表示は消える。
public struct PermissionHistory: Hashable, Sendable {
  public private(set) var grantedPermissions: Set<AppPermission>

  public init(grantedPermissions: Set<AppPermission> = []) {
    self.grantedPermissions = grantedPermissions
  }

  /// `PermissionOnboarding` / `FeatureAvailability` の `previous` に渡す状態
  public var previousSnapshot: PermissionSnapshot {
    PermissionSnapshot(
      Dictionary(uniqueKeysWithValues: grantedPermissions.map { ($0, .granted) }))
  }

  /// 観測した状態で、許可されている権限を覚える
  public mutating func record(_ snapshot: PermissionSnapshot) {
    grantedPermissions.formUnion(AppPermission.allCases.filter(snapshot.isGranted))
  }
}
